#!/bin/bash
set -e

# 切換到專案根目錄（支援從任何位置執行）
cd "$(dirname "$0")/.."

echo "=== Outline Wiki + Keycloak 快速部署腳本 ==="
echo ""

# 檢查 Docker
if ! command -v docker &> /dev/null; then
    echo "錯誤：請先安裝 Docker"
    exit 1
fi

# 輸入網域
read -p "請輸入 Outline Wiki 網域 (例如 wiki.example.com): " WIKI_DOMAIN
read -p "請輸入 Keycloak 網域 (例如 auth.example.com): " AUTH_DOMAIN
read -p "請輸入你的 Email (用於 SSL 憑證): " EMAIL

# 輸入用戶資訊
echo ""
echo "=== Keycloak 用戶設定 ==="
read -p "請輸入第一個用戶的 Email: " USER1_EMAIL
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
USER_TEMP_PASSWORD="changeme123"

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

# 更新 Nginx 設定
echo "正在更新 Nginx 設定..."
cp nginx/templates/outline.conf.template nginx/conf.d/outline.conf.ssl
cp nginx/templates/outline-temp.conf.template nginx/conf.d/outline-temp.conf
sed -i "s/WIKI_DOMAIN/${WIKI_DOMAIN}/g" nginx/conf.d/outline.conf.ssl
sed -i "s/AUTH_DOMAIN/${AUTH_DOMAIN}/g" nginx/conf.d/outline.conf.ssl
sed -i "s/WIKI_DOMAIN/${WIKI_DOMAIN}/g" nginx/conf.d/outline-temp.conf
sed -i "s/AUTH_DOMAIN/${AUTH_DOMAIN}/g" nginx/conf.d/outline-temp.conf

# 更新 Keycloak Realm JSON
echo "正在建立 Keycloak 用戶設定..."
cat > keycloak/outline-realm.json << EOF
{
  "realm": "outline",
  "enabled": true,
  "sslRequired": "external",
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,
  "resetPasswordAllowed": true,
  "editUsernameAllowed": false,
  "bruteForceProtected": true,
  "clients": [
    {
      "clientId": "outline",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "${OIDC_CLIENT_SECRET}",
      "redirectUris": ["https://${WIKI_DOMAIN}/*"],
      "webOrigins": ["https://${WIKI_DOMAIN}"],
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "authorizationServicesEnabled": false,
      "fullScopeAllowed": true,
      "defaultClientScopes": ["web-origins", "acr", "profile", "email"]
    }
  ],
  "users": [
    {
      "username": "${USER1_EMAIL}",
      "email": "${USER1_EMAIL}",
      "emailVerified": true,
      "enabled": true,
      "firstName": "${USER1_NAME}",
      "lastName": "",
      "credentials": [{"type": "password", "value": "${USER_TEMP_PASSWORD}", "temporary": true}]
    }
EOF

if [ -n "$USER2_EMAIL" ]; then
cat >> keycloak/outline-realm.json << EOF
    ,{
      "username": "${USER2_EMAIL}",
      "email": "${USER2_EMAIL}",
      "emailVerified": true,
      "enabled": true,
      "firstName": "${USER2_NAME}",
      "lastName": "",
      "credentials": [{"type": "password", "value": "${USER_TEMP_PASSWORD}", "temporary": true}]
    }
EOF
fi

cat >> keycloak/outline-realm.json << EOF
  ]
}
EOF

# 建立必要目錄
echo "正在建立目錄..."
mkdir -p data nginx/certs nginx/www
chmod 777 data

# 使用臨時 Nginx 設定
cp nginx/conf.d/outline-temp.conf nginx/conf.d/outline.conf

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
echo "3. 啟動服務並取得 SSL 憑證："
echo "   docker compose up -d postgres redis nginx"
echo "   docker compose exec postgres createdb -U outline keycloak"
echo ""
echo "4. 取得 SSL 憑證："
echo "   docker run --rm \\"
echo "     -v \$(pwd)/nginx/certs:/etc/letsencrypt \\"
echo "     -v \$(pwd)/nginx/www:/var/www/certbot \\"
echo "     certbot/certbot certonly --webroot \\"
echo "     -w /var/www/certbot \\"
echo "     -d ${WIKI_DOMAIN} -d ${AUTH_DOMAIN} \\"
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
echo "  密碼: ${KEYCLOAK_ADMIN_PASSWORD}"
echo ""
echo "用戶登入密碼 (首次登入需更改): ${USER_TEMP_PASSWORD}"
echo ""
echo "請妥善保存以上資訊！"
