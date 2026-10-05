#!/bin/bash
# 自動偵測並復原 Docker Desktop / WSL2 的 bind mount 脫鉤。
#
# 背景：Docker Desktop 的 WSL bind-mount 快取與 host inode 脫鉤之後，容器會照常啟動，
# 但掛載點是空的。nginx 因此沒有任何 listen 443 server block，443 收到連線立刻 EOF，
# CDN 回 525。healthcheck 抓得到（會標 unhealthy），但 healthcheck 不會自己動手——
# 2026-10-02 那次就這樣掛了 67.8 小時沒人發現。本腳本補的就是「動手」那一段。
#
# 安裝：make watchdog-install（裝 @reboot 與 */5 兩條 crontab）
# 查看：make watchdog-status

set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
PROJECT_DIR=$(pwd)

LOCKFILE=/tmp/outline-docker-watchdog.lock
LOGFILE="$HOME/.outline-docker-watchdog.log"
STATEFILE="$HOME/.outline-docker-watchdog.state"
CONFFILE="$HOME/.outline-docker-watchdog.conf"

# 一小時內最多復原幾次。沒有這個限制的話，當 Docker Desktop 的快取整個壞掉、
# 重建也救不回來時，守護會每 5 分鐘 down/up 一次無限迴圈。
MAX_RECOVERIES_PER_HOUR=2

# 可插拔推播：在 $CONFFILE 裡填 WEBHOOK_URL=... 就會 POST 通知。
# 這台機器沒有 notify-send / mail / sendmail，Prometheus 也沒有 alertmanager，
# 所以預設只有本機記錄。
WEBHOOK_URL=""
# shellcheck source=/dev/null
[ -f "$CONFFILE" ] && . "$CONFFILE"

log() {
    local level="$1" msg="$2"
    printf '%s [%s] %s\n' "$(date -Iseconds)" "$level" "$msg" >> "$LOGFILE"
    command -v logger >/dev/null && logger -t outline-watchdog -p "user.${level,,}" -- "$msg"
}

notify() {
    local msg="$1"
    [ -n "$WEBHOOK_URL" ] || return 0
    # 同時相容 Slack / Discord（兩者都吃 JSON，鍵名不同故一起帶）
    local payload
    payload=$(printf '{"text":%s,"content":%s}' \
        "$(printf '%s' "$msg" | jq -Rs .)" "$(printf '%s' "$msg" | jq -Rs .)")
    curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
        -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 \
        || log WARNING "webhook 推播失敗"
}

# ============================================
# 互斥：兩次 cron 重疊時直接退出
# ============================================
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    exit 0
fi

# ============================================
# 觸發條件：三條全中才動作
# ============================================
# 1. 容器正在執行？（不是使用者自己 make down 停掉的）
running=$(docker compose ps --status running --format '{{.Service}}' 2>/dev/null | wc -l)
if [ "$running" -eq 0 ]; then
    log INFO "容器未執行（可能是刻意停機），略過"
    exit 0
fi

# 2. host 端的設定檔還在嗎？（不在的話問題不是掛載，是檔案被刪了，不該亂重建）
if [ ! -s "$PROJECT_DIR/nginx/conf.d/outline.conf" ]; then
    log ERROR "host 端 nginx/conf.d/outline.conf 不存在或是空的——這不是掛載問題，需要人介入"
    notify "⚠ outline-docker: host 端 nginx 設定檔遺失，守護不處理，需要人介入"
    exit 1
fi

# 3. 容器內看得到設定檔嗎？看得到就一切正常
if docker compose exec -T nginx sh -c 'ls /etc/nginx/conf.d/*.conf >/dev/null 2>&1' 2>/dev/null; then
    log INFO "檢查通過，未動作"
    exit 0
fi

# ============================================
# 到這裡 = 確定是 bind mount 脫鉤
# ============================================
log ERROR "偵測到 bind mount 脫鉤：容器在跑、host 設定檔存在，但容器內 /etc/nginx/conf.d 是空的"

# 速率限制：看 state 檔裡一小時內的復原次數
now=$(date +%s)
recent=0
if [ -f "$STATEFILE" ]; then
    while read -r ts; do
        [ -n "$ts" ] || continue
        [ $((now - ts)) -lt 3600 ] && recent=$((recent + 1))
    done < "$STATEFILE"
fi

if [ "$recent" -ge "$MAX_RECOVERIES_PER_HOUR" ]; then
    log ERROR "一小時內已復原 $recent 次，達上限不再嘗試。Docker Desktop 的 bind-mount 快取可能整個壞了，需要在 Windows 端重啟 Docker Desktop"
    notify "🔴 outline-docker: 自動復原連續失敗（1 小時內 $recent 次），需要人介入——請在 Windows 端重啟 Docker Desktop 後跑 make recover"
    exit 1
fi

# ============================================
# 復原
# ============================================
log WARNING "開始自動復原（第 $((recent + 1)) 次／本小時）"
notify "⚠ outline-docker: 偵測到 bind mount 脫鉤，正在自動復原…"

# 記錄這次嘗試（在動作前就寫，確保失敗也會計入速率限制）
{ [ -f "$STATEFILE" ] && awk -v n="$now" '$1 > n-3600' "$STATEFILE"; echo "$now"; } > "$STATEFILE.tmp" \
    && mv "$STATEFILE.tmp" "$STATEFILE"

recover_out=$(docker compose down --remove-orphans 2>&1 && docker compose up -d 2>&1)
recover_rc=$?

if [ "$recover_rc" -ne 0 ]; then
    log ERROR "docker compose 重建失敗：$(printf '%s' "$recover_out" | tail -3 | tr '\n' ' ')"
    notify "🔴 outline-docker: 自動復原失敗，docker compose 重建回傳非 0"
    exit 1
fi

# ============================================
# 複驗：重建完不代表修好了，要實際確認
# ============================================
for _ in $(seq 1 24); do
    sleep 5
    docker compose exec -T nginx sh -c 'ls /etc/nginx/conf.d/*.conf >/dev/null 2>&1' 2>/dev/null && break
done

if ! docker compose exec -T nginx sh -c 'ls /etc/nginx/conf.d/*.conf >/dev/null 2>&1' 2>/dev/null; then
    log ERROR "復原後掛載仍是空的——Docker Desktop 的 bind-mount 快取本身壞了"
    notify "🔴 outline-docker: 重建後掛載仍為空，請在 Windows 端重啟 Docker Desktop"
    exit 1
fi

wiki_domain=$(grep -E '^URL=' .env 2>/dev/null | head -1 | cut -d= -f2- \
    | tr -d '\r' | tr -d '"' | tr -d "'" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[/:].*##')
code="(未測)"
if [ -n "$wiki_domain" ]; then
    code=$(curl -sSk -o /dev/null -w '%{http_code}' --max-time 15 \
        --resolve "${wiki_domain}:443:127.0.0.1" "https://${wiki_domain}/" 2>/dev/null || echo "000")
fi

if [ "$code" = "000" ]; then
    log ERROR "掛載已復原，但 origin 仍握手失敗（HTTP $code）"
    notify "🔴 outline-docker: 掛載已復原但 origin 仍不通，需要人介入"
    exit 1
fi

log INFO "自動復原成功（origin HTTP $code）"
notify "✅ outline-docker: 自動復原成功，origin HTTP $code"
exit 0
