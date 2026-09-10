#!/bin/bash
set -e

# 切換到專案根目錄
# readlink -f：若日後有 symlink 指向本檔，$0 不解析 symlink 會 cd 錯地方
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 計數器
PASS=0
FAIL=0

# 輔助函數
print_header() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_pass() {
    echo -e "${GREEN}✓${NC} $1"
    PASS=$((PASS + 1))
}

print_fail() {
    echo -e "${RED}✗${NC} $1"
    FAIL=$((FAIL + 1))
}

print_skip() {
    echo -e "${YELLOW}○${NC} $1 (跳過)"
}

print_header "Outline Docker 專案驗證"

# ============================================
# 1. ShellCheck - Shell 腳本語法檢查
# ============================================
print_header "1. ShellCheck - Shell 腳本檢查"

if command -v shellcheck &> /dev/null; then
    if shellcheck scripts/*.sh 2>/dev/null; then
        print_pass "Shell 腳本語法正確"
    else
        print_fail "Shell 腳本有問題，請執行 shellcheck scripts/*.sh 查看詳情"
    fi
else
    print_skip "shellcheck 未安裝 (apt install shellcheck)"
fi

# ============================================
# 2. YAML 格式驗證
# ============================================
print_header "2. YAML 格式驗證"

if command -v yamllint &> /dev/null; then
    if yamllint -d "{extends: relaxed, rules: {line-length: disable}}" docker-compose.yml 2>/dev/null; then
        print_pass "docker-compose.yml 格式正確"
    else
        print_fail "docker-compose.yml 格式有問題"
    fi
else
    # 備用方案：使用 python yaml
    if command -v python3 &> /dev/null; then
        if python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))" 2>/dev/null; then
            print_pass "docker-compose.yml 語法正確 (使用 Python yaml)"
        else
            print_fail "docker-compose.yml 語法錯誤"
        fi
    else
        print_skip "yamllint 未安裝 (pip install yamllint)"
    fi
fi

# ============================================
# 3. JSON 格式驗證
# ============================================
print_header "3. JSON 格式驗證"

if command -v jq &> /dev/null; then
    # 範本一定要在（版控中的事實源）；實體檔只有跑過 setup.sh 的機器才有
    if [ -f "keycloak/import/outline-realm.json.template" ]; then
        if jq empty keycloak/import/outline-realm.json.template 2>/dev/null; then
            print_pass "keycloak/import/outline-realm.json.template 格式正確"
        else
            print_fail "keycloak/import/outline-realm.json.template 格式錯誤"
        fi
    else
        print_fail "keycloak/import/outline-realm.json.template 不存在"
    fi

    if [ -f "keycloak/import/outline-realm.json" ]; then
        if jq empty keycloak/import/outline-realm.json 2>/dev/null; then
            print_pass "keycloak/import/outline-realm.json 格式正確"
        else
            print_fail "keycloak/import/outline-realm.json 格式錯誤"
        fi
    else
        print_skip "keycloak/import/outline-realm.json 不存在 (執行 setup.sh 後生成)"
    fi
else
    print_skip "jq 未安裝 (apt install jq)"
fi

# ============================================
# 4. 環境變數範本驗證
# ============================================
print_header "4. 環境變數範本驗證"

if [ -f ".env.example" ]; then
    # 檢查必要的環境變數是否都有定義
    REQUIRED_VARS=(
        "SECRET_KEY"
        "UTILS_SECRET"
        "POSTGRES_PASSWORD"
        "DATABASE_URL"
        "REDIS_URL"
        "OIDC_CLIENT_ID"
        "OIDC_CLIENT_SECRET"
    )

    MISSING=0
    for var in "${REQUIRED_VARS[@]}"; do
        if ! grep -q "^${var}=" .env.example; then
            echo "  缺少必要變數: $var"
            MISSING=1
        fi
    done

    if [ $MISSING -eq 0 ]; then
        print_pass ".env.example 包含所有必要變數"
    else
        print_fail ".env.example 缺少必要變數"
    fi
else
    print_fail ".env.example 不存在"
fi

# ============================================
# 5. Docker Compose 驗證
# ============================================
print_header "5. Docker Compose 驗證"

if command -v docker &> /dev/null; then
    # 建立臨時 .env 檔案用於驗證 (如果不存在)
    # 只在 .env 不存在時借用 .env.example。務必用 trap 清理：
    # 沒有 trap 的話，中途 Ctrl-C 會在機器上留下一個全是佔位值的 .env。
    TEMP_ENV=0
    if [ ! -f ".env" ]; then
        cp .env.example .env 2>/dev/null || true
        TEMP_ENV=1
        trap 'rm -f .env' EXIT INT TERM
    fi

    if COMPOSE_ERR=$(docker compose config 2>&1 >/dev/null); then
        print_pass "docker-compose.yml 設定有效"
    else
        print_fail "docker-compose.yml 設定無效"
        echo "$COMPOSE_ERR"
    fi

    if [ $TEMP_ENV -eq 1 ]; then
        rm -f .env
        trap - EXIT INT TERM
    fi
else
    print_skip "docker 未安裝"
fi

# ============================================
# 6. Nginx 設定模板驗證
# ============================================
print_header "6. Nginx 設定模板驗證"

# 結構檢查（不需要 Docker）
for tpl in nginx/templates/outline.conf.template nginx/templates/outline-temp.conf.template; do
    if [ ! -f "$tpl" ]; then
        print_fail "$tpl 不存在"
        continue
    fi
    if grep -q "server {" "$tpl"; then
        print_pass "$tpl 結構正確"
    else
        print_fail "$tpl 結構不完整"
    fi
done

# 真正的語法檢查：把模板渲染出來後在容器內跑 nginx -t。
# 早期版本只做上面的 grep，抓不到 conflicting server name 這類問題——
# 而那正是「照文件安裝後 80 埠行為錯誤」的成因。
if command -v docker &> /dev/null; then
    NGINX_TMP=$(mktemp -d)
    trap 'rm -rf "$NGINX_TMP"' EXIT

    mkdir -p "$NGINX_TMP/conf.d" "$NGINX_TMP/certs/live/validate.example"
    # upstream 名稱在 CI 沒有 compose 網路可解析，換成 127.0.0.1 才驗得了語法
    sed -e 's/WIKI_DOMAIN/validate.example/g' \
        -e 's/AUTH_DOMAIN/auth.validate.example/g' \
        -e 's#http://outline:3000#http://127.0.0.1:3000#' \
        -e 's#http://keycloak:8080#http://127.0.0.1:8080#' \
        nginx/templates/outline.conf.template > "$NGINX_TMP/conf.d/outline.conf"

    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$NGINX_TMP/certs/live/validate.example/privkey.pem" \
        -out "$NGINX_TMP/certs/live/validate.example/fullchain.pem" \
        -subj "/CN=validate.example" &> /dev/null

    if NGINX_OUT=$(docker run --rm \
            -v "$NGINX_TMP/conf.d:/etc/nginx/conf.d:ro" \
            -v "$NGINX_TMP/certs:/etc/letsencrypt:ro" \
            nginx:alpine nginx -t 2>&1); then
        if printf '%s' "$NGINX_OUT" | grep -qiE "conflicting server name|\[warn\]"; then
            print_fail "nginx -t 通過但有警告"
            printf '%s\n' "$NGINX_OUT" | grep -iE "conflicting|warn"
        else
            print_pass "nginx -t 語法檢查通過且無警告"
        fi
    else
        print_fail "nginx -t 語法檢查失敗"
        printf '%s\n' "$NGINX_OUT" | grep -iE "emerg|error" | head -5
    fi

    rm -rf "$NGINX_TMP"
    trap - EXIT
else
    print_skip "nginx -t 語法檢查 (需要 docker)"
fi

# ============================================
# 7. 必要檔案檢查
# ============================================
print_header "7. 必要檔案檢查"

REQUIRED_FILES=(
    "docker-compose.yml"
    ".env.example"
    "scripts/setup.sh"
    "scripts/initdb/init-keycloak-db.sql"
    "keycloak/import/outline-realm.json.template"
    "nginx/templates/outline.conf.template"
    "nginx/templates/outline-temp.conf.template"
    "README.md"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        print_pass "$file 存在"
    else
        print_fail "$file 不存在"
    fi
done

# ============================================
# 結果摘要
# ============================================
print_header "驗證結果"

TOTAL=$((PASS + FAIL))
echo ""
echo -e "通過: ${GREEN}${PASS}${NC}"
echo -e "失敗: ${RED}${FAIL}${NC}"
echo -e "總計: ${TOTAL}"
echo ""

if [ $FAIL -gt 0 ]; then
    echo -e "${RED}驗證失敗！請修正上述問題後再提交。${NC}"
    exit 1
else
    echo -e "${GREEN}所有驗證通過！${NC}"
    exit 0
fi
