#!/bin/bash
# 唯讀健康診斷：專治 Docker Desktop / WSL2 重啟後 bind mount 失效的故障
#
# 背景：Docker Desktop 的 WSL bind-mount 快取與 host inode 脫鉤時會有兩種壞法──
#   目錄掛載 → 靜默掛成空目錄，容器照樣啟動（nginx 因此沒有任何 server block）
#   單檔掛載 → 硬失敗 exit 127，容器起不來
# 前者最難查，因為 `nginx -t` 會通過（沒有 config 可以失敗），而 Cloudflare 只回一個 525。

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

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

print_warn() {
    echo -e "${YELLOW}○${NC} $1"
}

# 從 .env 取得網域（沒有就用 URL 推導，再不然給預設值）
WIKI_DOMAIN=""
AUTH_DOMAIN=""
if [ -f .env ]; then
    WIKI_DOMAIN=$(grep -E '^URL=' .env | head -1 | sed -e 's#^URL=https\?://##' -e 's#/.*##')
    AUTH_DOMAIN=$(grep -E '^AUTH_DOMAIN=' .env | head -1 | cut -d= -f2-)
fi
[ -n "$WIKI_DOMAIN" ] || WIKI_DOMAIN="wiki.example.com"
[ -n "$AUTH_DOMAIN" ] || AUTH_DOMAIN="auth.example.com"

print_header "Outline Docker 健康診斷"
echo "wiki: $WIKI_DOMAIN"
echo "auth: $AUTH_DOMAIN"

# ============================================
# 1. 服務狀態
# ============================================
print_header "1. 服務狀態"

if ! docker compose ps --format '{{.Service}}' >/dev/null 2>&1; then
    print_fail "無法連上 Docker，請確認 Docker Desktop 正在執行"
    exit 1
fi

for svc in outline postgres redis keycloak nginx certbot; do
    state=$(docker compose ps -a --format '{{.Service}} {{.State}}' 2>/dev/null \
            | awk -v s="$svc" '$1==s {print $2}' | head -1)
    if [ -z "$state" ]; then
        print_fail "$svc 沒有容器（尚未 docker compose up？）"
    elif [ "$state" = "running" ]; then
        print_pass "$svc running"
    else
        code=$(docker inspect "$(docker compose ps -aq "$svc" 2>/dev/null | head -1)" \
               --format '{{.State.ExitCode}}' 2>/dev/null || echo "?")
        if [ "$code" = "127" ]; then
            print_fail "$svc $state (exit 127) ← 單檔 bind mount 失效，跑 make recover"
        else
            print_fail "$svc $state (exit $code)"
        fi
    fi
done

# ============================================
# 2. 掛載點是否被掛成空目錄（本專案最陰險的故障）
# ============================================
print_header "2. 容器內掛載點內容"

check_mount() {
    svc="$1"; path="$2"; label="$3"
    if ! docker compose ps --format '{{.Service}}' 2>/dev/null | grep -qx "$svc"; then
        print_warn "$label 跳過（$svc 沒在跑）"
        return
    fi
    if docker compose exec -T "$svc" sh -c "ls -A '$path' 2>/dev/null | grep -q ." 2>/dev/null; then
        print_pass "$label 有內容"
    else
        print_fail "$label 是空的 ← bind mount 掛空了，跑 make recover"
    fi
}

check_mount nginx    /etc/nginx/conf.d                 "nginx  /etc/nginx/conf.d"
check_mount nginx    /etc/letsencrypt/live             "nginx  /etc/letsencrypt/live"
check_mount postgres /docker-entrypoint-initdb.d       "pg     /docker-entrypoint-initdb.d"
check_mount keycloak /opt/keycloak/data/import         "kc     /opt/keycloak/data/import"
check_mount certbot  /opt/scripts                      "certbot /opt/scripts"

# nginx 真的有載入 SSL server block 嗎
if docker compose ps --format '{{.Service}}' 2>/dev/null | grep -qx nginx; then
    n=$(docker compose exec -T nginx sh -c 'nginx -T 2>/dev/null | grep -c "listen 443"' 2>/dev/null | tr -d '\r')
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
        print_pass "nginx 已載入 $n 個 listen 443 server block"
    else
        print_fail "nginx 沒有任何 listen 443 ← 443 收到連線後會直接 EOF，外部看到 SSL handshake failed"
    fi
fi

# ============================================
# 3. Origin TLS（繞過 CDN，直打本機 443）
# ============================================
print_header "3. Origin TLS（繞過 CDN）"

origin_code=$(curl -sSk -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "${WIKI_DOMAIN}:443:127.0.0.1" "https://${WIKI_DOMAIN}/" 2>/dev/null || echo "000")
if [ "$origin_code" = "000" ]; then
    print_fail "origin 握手失敗（$WIKI_DOMAIN）← nginx 沒有 SSL server block 或憑證讀不到"
else
    print_pass "origin HTTP $origin_code（$WIKI_DOMAIN）"
fi

# ============================================
# 4. 端到端（經 CDN／公網）
# ============================================
print_header "4. 端到端（經公網）"

for d in "$WIKI_DOMAIN" "$AUTH_DOMAIN"; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://${d}/" 2>/dev/null || echo "000")
    case "$code" in
        525)
            print_fail "$d → 525：Cloudflare 到 origin 握手失敗，先跑 make recover"
            ;;
        521|522|523)
            print_fail "$d → $code：Cloudflare 連不到 origin（服務沒起來或防火牆）"
            ;;
        000)
            print_fail "$d → 連不上（DNS／網路／逾時）"
            ;;
        2*|3*)
            print_pass "$d → HTTP $code"
            ;;
        *)
            print_warn "$d → HTTP $code"
            ;;
    esac
done

# ============================================
# 5. 憑證到期日（不依賴 certbot 容器在跑）
# ============================================
print_header "5. 憑證到期日"

cert_end=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$WIKI_DOMAIN" 2>/dev/null \
           | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -n "$cert_end" ]; then
    end_ts=$(date -d "$cert_end" +%s 2>/dev/null || echo "")
    if [ -n "$end_ts" ]; then
        days=$(( (end_ts - $(date +%s)) / 86400 ))
        if [ "$days" -lt 0 ]; then
            print_fail "origin 憑證已過期（$cert_end）"
        elif [ "$days" -lt 21 ]; then
            print_fail "origin 憑證剩 $days 天到期（$cert_end）← 自動更新可能沒在運作"
        else
            print_pass "origin 憑證剩 $days 天到期（$cert_end）"
        fi
    else
        print_pass "origin 憑證到期：$cert_end"
    fi
else
    print_fail "讀不到 origin 憑證（443 上沒有可用的 TLS）"
fi

# ============================================
# 總結
# ============================================
print_header "診斷結果"
echo -e "${GREEN}通過: $PASS${NC}"
echo -e "${RED}失敗: $FAIL${NC}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "多數 bind mount 相關故障可用以下指令修復："
    echo "  make recover"
    echo ""
    echo "若 make recover 後掛載仍是空的，代表 Docker Desktop 的 bind-mount 快取本身壞了，"
    echo "需在 Windows 端重啟 Docker Desktop 再跑一次 make recover。"
    exit 1
fi

echo "全部通過。"
