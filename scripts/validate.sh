#!/bin/bash
set -e

# 切換到專案根目錄
cd "$(dirname "$0")/.."

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
    if shellcheck scripts/setup.sh scripts/validate.sh 2>/dev/null; then
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
    # 驗證 Keycloak realm.json (如果存在)
    if [ -f "keycloak/outline-realm.json" ]; then
        if jq empty keycloak/outline-realm.json 2>/dev/null; then
            print_pass "keycloak/outline-realm.json 格式正確"
        else
            print_fail "keycloak/outline-realm.json 格式錯誤"
        fi
    else
        print_skip "keycloak/outline-realm.json 不存在 (執行 setup.sh 後生成)"
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
    TEMP_ENV=0
    if [ ! -f ".env" ]; then
        cp .env.example .env 2>/dev/null || true
        TEMP_ENV=1
    fi

    if docker compose config > /dev/null 2>&1; then
        print_pass "docker-compose.yml 設定有效"
    else
        print_fail "docker-compose.yml 設定無效"
    fi

    # 清理臨時檔案
    if [ $TEMP_ENV -eq 1 ]; then
        rm -f .env
    fi
else
    print_skip "docker 未安裝"
fi

# ============================================
# 6. Nginx 設定模板驗證
# ============================================
print_header "6. Nginx 設定模板驗證"

# 檢查模板檔案存在
if [ -f "nginx/templates/outline.conf.template" ]; then
    # 基本語法檢查：確認有必要的區塊
    if grep -q "server {" nginx/templates/outline.conf.template && \
       grep -q "location" nginx/templates/outline.conf.template; then
        print_pass "nginx/templates/outline.conf.template 結構正確"
    else
        print_fail "nginx/templates/outline.conf.template 結構不完整"
    fi
else
    print_fail "nginx/templates/outline.conf.template 不存在"
fi

if [ -f "nginx/templates/outline-temp.conf.template" ]; then
    if grep -q "server {" nginx/templates/outline-temp.conf.template; then
        print_pass "nginx/templates/outline-temp.conf.template 結構正確"
    else
        print_fail "nginx/templates/outline-temp.conf.template 結構不完整"
    fi
else
    print_fail "nginx/templates/outline-temp.conf.template 不存在"
fi

# ============================================
# 7. 必要檔案檢查
# ============================================
print_header "7. 必要檔案檢查"

REQUIRED_FILES=(
    "docker-compose.yml"
    ".env.example"
    "scripts/setup.sh"
    "scripts/init-keycloak-db.sql"
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
