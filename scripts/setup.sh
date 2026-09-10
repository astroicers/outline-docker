#!/bin/bash
set -e

# 切換到專案根目錄。必須用 readlink -f：根目錄的 setup.sh 是指向本檔的 symlink，
# 而 bash 不解析 $0 的 symlink——不這樣寫的話 `./setup.sh` 會 cd 到專案的「上一層」，
# 把含全部密鑰的 .env 寫到那裡去。
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1

echo "=== Outline Wiki + Keycloak 快速部署腳本 ==="
echo ""

# 檢查 Docker
if ! command -v docker &> /dev/null; then
    echo "錯誤：請先安裝 Docker"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "錯誤：請先安裝 jq（用於安全地產生 Keycloak realm 設定）"
    exit 1
fi

# 這四個由下面的 require_* 以 printf -v 間接賦值，先宣告讓 shellcheck 追得到
WIKI_DOMAIN=""
AUTH_DOMAIN=""
EMAIL=""
USER1_EMAIL=""

# 輸入驗證：空值或格式錯誤會靜默產生壞掉的設定，所以在這裡擋住
require_domain() {
    # $1=提示字串 $2=變數名
    local value
    while :; do
        read -p "$1" value
        if printf '%s' "$value" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'; then
            printf -v "$2" '%s' "$value"
            return
        fi
        echo "  請輸入合法網域（例如 wiki.example.com），不要帶 https:// 或路徑"
    done
}

require_email() {
    local value
    while :; do
        read -p "$1" value
        if printf '%s' "$value" | grep -qE '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'; then
            printf -v "$2" '%s' "$value"
            return
        fi
        echo "  請輸入合法 Email"
    done
}

# 輸入網域
require_domain "請輸入 Outline Wiki 網域 (例如 wiki.example.com): " WIKI_DOMAIN
require_domain "請輸入 Keycloak 網域 (例如 auth.example.com): " AUTH_DOMAIN
require_email  "請輸入你的 Email (用於 SSL 憑證): " EMAIL

# 輸入用戶資訊
echo ""
echo "=== Keycloak 用戶設定 ==="
require_email "請輸入第一個用戶的 Email: " USER1_EMAIL
read -p "請輸入第一個用戶的名稱: " USER1_NAME
read -p "請輸入第二個用戶的 Email (留空跳過): " USER2_EMAIL
if [ -n "$USER2_EMAIL" ]; then
    read -p "請輸入第二個用戶的名稱: " USER2_NAME
fi

# 產生密鑰
echo ""
echo "正在產生安全金鑰..."
SECRET_KEY=$(openssl rand -hex 32)
UTILS_SECRET=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -hex 32)
OIDC_CLIENT_SECRET=$(openssl rand -hex 32)
# 每位使用者各自一組隨機初始密碼。原本這裡是硬編碼常數，而它會進公開版控——
# 等於「已知 email + 已知密碼」，攻擊者可搶在本人之前登入並改掉密碼。
USER1_TEMP_PASSWORD=$(openssl rand -base64 12)
USER2_TEMP_PASSWORD=$(openssl rand -base64 12)

# 建立 .env
echo "正在建立 .env 設定檔..."
cat > .env << EOF
NODE_ENV=production
URL=https://${WIKI_DOMAIN}
PORT=3000
AUTH_DOMAIN=${AUTH_DOMAIN}

# Security Keys
SECRET_KEY=${SECRET_KEY}
UTILS_SECRET=${UTILS_SECRET}

# Database
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
DATABASE_URL=postgres://outline:${POSTGRES_PASSWORD}@postgres:5432/outline
PGSSLMODE=disable

# Redis
REDIS_URL=redis://redis:6379

# File Storage
FILE_STORAGE=local
FILE_STORAGE_LOCAL_ROOT_DIR=/var/lib/outline/data
FILE_STORAGE_UPLOAD_MAX_SIZE=262144000

# Keycloak Admin
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}

# Keycloak 使用者初始密碼（首次登入須更改）
USER1_TEMP_PASSWORD=${USER1_TEMP_PASSWORD}
USER2_TEMP_PASSWORD=${USER2_TEMP_PASSWORD}

# OIDC (Keycloak)
OIDC_CLIENT_ID=outline
OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
OIDC_AUTH_URI=https://${AUTH_DOMAIN}/realms/outline/protocol/openid-connect/auth
OIDC_TOKEN_URI=https://${AUTH_DOMAIN}/realms/outline/protocol/openid-connect/token
OIDC_USERINFO_URI=https://${AUTH_DOMAIN}/realms/outline/protocol/openid-connect/userinfo
OIDC_LOGOUT_URI=https://${AUTH_DOMAIN}/realms/outline/protocol/openid-connect/logout
OIDC_DISPLAY_NAME=Keycloak
OIDC_SCOPES=openid profile email

# SSL
FORCE_HTTPS=true

# Rate Limiter
RATE_LIMITER_ENABLED=true
RATE_LIMITER_REQUESTS=1000
RATE_LIMITER_DURATION_WINDOW=60

# Optional
DEFAULT_LANGUAGE=zh_TW
WEB_CONCURRENCY=1
LOG_LEVEL=info
EOF

# .env 含全部密鑰，不可沿用預設 umask（通常是 644，同機他人可讀）
chmod 600 .env

# 先建立目錄，後面的 cp 才有地方放（原本 mkdir 在這之後，順序是錯的）
echo "正在建立目錄..."
mkdir -p data nginx/certs nginx/www nginx/conf.d

# 更新 Nginx 設定
# 注意 temp 檔刻意用 .tmpl 而非 .conf 副檔名：nginx 載入的是 conf.d/*.conf，
# 若 temp 檔也叫 .conf，切換到 SSL 設定後它會一起被載入，且 glob 排序在 outline.conf
# 之前（'-' < '.'），導致 80 埠一直回「Waiting for SSL certificate...」而不是 301。
echo "正在更新 Nginx 設定..."
cp nginx/templates/outline.conf.template nginx/conf.d/outline.conf.ssl
cp nginx/templates/outline-temp.conf.template nginx/conf.d/outline-temp.conf.tmpl
sed -i "s/WIKI_DOMAIN/${WIKI_DOMAIN}/g" nginx/conf.d/outline.conf.ssl
sed -i "s/AUTH_DOMAIN/${AUTH_DOMAIN}/g" nginx/conf.d/outline.conf.ssl
sed -i "s/WIKI_DOMAIN/${WIKI_DOMAIN}/g" nginx/conf.d/outline-temp.conf.tmpl
sed -i "s/AUTH_DOMAIN/${AUTH_DOMAIN}/g" nginx/conf.d/outline-temp.conf.tmpl

# 產生 Keycloak Realm 設定
# 用 jq 從範本填值，不用字串內插：使用者姓名若含 " 或 \ 會破壞 JSON，
# 導致 Keycloak 啟動時匯入失敗。產物含真實 client secret，故 .gitignore 已排除 *.json。
echo "正在建立 Keycloak 用戶設定..."

user_entry() {
    jq -n --arg e "$1" --arg n "$2" --arg p "$3" \
        '{username:$e, email:$e, emailVerified:true, enabled:true,
          firstName:$n, lastName:"",
          credentials:[{type:"password", value:$p, temporary:true}]}'
}

USERS_JSON=$(user_entry "$USER1_EMAIL" "$USER1_NAME" "$USER1_TEMP_PASSWORD" | jq -s '.')
if [ -n "$USER2_EMAIL" ]; then
    USERS_JSON=$(printf '%s' "$USERS_JSON" \
        | jq --argjson u "$(user_entry "$USER2_EMAIL" "$USER2_NAME" "$USER2_TEMP_PASSWORD")" '. + [$u]')
fi

jq --arg secret "$OIDC_CLIENT_SECRET" \
   --arg wiki "https://${WIKI_DOMAIN}" \
   --argjson users "$USERS_JSON" \
   '.clients[0].secret = $secret
    | .clients[0].redirectUris = [$wiki + "/*"]
    | .clients[0].webOrigins = [$wiki]
    | .users = $users' \
   keycloak/import/outline-realm.json.template > keycloak/import/outline-realm.json
chmod 600 keycloak/import/outline-realm.json

# Outline 容器以 uid 1001 執行，需要的只是該 uid 可寫，不是全世界可寫。
# 沒有 root 權限時退回 777 並提醒——但那會讓主機上任何使用者都能讀寫使用者上傳的附件。
if ! chown -R 1001:1001 data 2>/dev/null; then
    chmod 777 data
    echo "  注意：無法 chown data/（需要 sudo），已退回 chmod 777。"
    echo "  建議事後執行：sudo chown -R 1001:1001 data && chmod 755 data"
fi

# 先用臨時的 HTTP-only 設定，讓 certbot 能走 webroot 驗證
cp nginx/conf.d/outline-temp.conf.tmpl nginx/conf.d/outline.conf

echo ""
echo "=== 設定完成！==="
echo ""
echo "接下來請執行以下步驟："
echo ""
echo "1. 設定 DNS，將以下網域指向你的伺服器 IP："
echo "   - ${WIKI_DOMAIN}"
echo "   - ${AUTH_DOMAIN}"
echo ""
echo "2. 確保路由器/防火牆開啟 port 80 和 443"
echo ""
echo "3. 啟動基礎服務："
echo "   docker compose up -d postgres redis nginx"
echo "   （keycloak 資料庫由 scripts/initdb/init-keycloak-db.sql 在 postgres 首次初始化時自動建立，"
echo "     不需要手動 createdb）"
echo ""
echo "4. 取得 SSL 憑證："
echo "   docker run --rm \\"
echo "     -v \$(pwd)/nginx/certs:/etc/letsencrypt \\"
echo "     -v \$(pwd)/nginx/www:/var/www/certbot \\"
echo "     -v \$(pwd)/scripts:/opt/scripts:ro \\"
echo "     certbot/certbot certonly --webroot \\"
echo "     -w /var/www/certbot \\"
echo "     -d ${WIKI_DOMAIN} -d ${AUTH_DOMAIN} \\"
echo "     --deploy-hook /opt/scripts/deploy-hook.sh \\"
echo "     --email ${EMAIL} --agree-tos --non-interactive"
echo ""
echo "5. 切換到 SSL 設定並啟動所有服務："
echo "   cp nginx/conf.d/outline.conf.ssl nginx/conf.d/outline.conf"
echo "   docker compose up -d"
echo ""
echo "=== 登入資訊 ==="
echo ""
echo "Outline Wiki: https://${WIKI_DOMAIN}"
echo ""
echo "Keycloak 管理後台: https://${AUTH_DOMAIN}/admin"
echo "  帳號: admin"
echo ""
echo "密碼不在此輸出（避免留在終端 scrollback 與終端機日誌中），請從 .env 取得："
echo "  Keycloak admin：  grep KEYCLOAK_ADMIN_PASSWORD .env"
echo "  使用者初始密碼：  grep USER._TEMP_PASSWORD .env"
echo ""
echo ".env 權限已設為 600。請妥善保管，並在首次登入後立即更改密碼。"
