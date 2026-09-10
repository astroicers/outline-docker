# Certbot 自動更新 Docker Service

## 背景

Let's Encrypt 憑證有效期為 90 天。目前憑證（`wiki.astroicers.link`、`auth.astroicers.link`）採手動更新方式維護，最近一次更新於 2026-05-08，到期日為 2026-08-08。

手動維護存在以下風險：
- 人為疏忽導致憑證過期，造成服務中斷（HTTPS 失效，使用者瀏覽器顯示安全警告）
- 無法在非工作時間及時回應到期事件
- 更新步驟依賴操作人員記憶，缺乏一致性

需要一個自動化機制，在憑證到期前 30 天內自動完成更新，並通知 Nginx 套用新憑證，無需人工介入。

## 目標

1. 消除手動執行 `certbot renew` 的維運負擔
2. 憑證到期前 30 天內自動完成續期
3. 續期後 Nginx 無停機套用新憑證（SIGHUP reload）
4. 提供 `make cert-status` 與 `make cert-renew` 指令供維運人員查詢與強制更新

## 方案

### 變更內容

- `docker-compose.yml` - 新增 `certbot` service（使用官方 `certbot/certbot` image），entrypoint 為 12 小時循環執行 `certbot renew`
- `scripts/deploy-hook.sh` - 新增 deploy hook，透過 Docker socket 對 nginx container 發送 SIGHUP，觸發憑證 reload
- `Makefile` - 新增 `cert-status` 與 `cert-renew` 目標

詳細實作步驟請參閱：[docs/plans/2026-05-10-certbot-auto-renew.md](../plans/2026-05-10-certbot-auto-renew.md)

### 設定變更

> ⚠ **本節為 2026-05-10 當時的規劃，已被後續變更取代。**
> 實際生效的設定以 `docker-compose.yml` 為準，**不要把下面這段抄回去**——
> 它用的是單檔 bind mount，而那正是 2026-09-10 線上事故（Cloudflare 525）的成因之一。

實際與規劃的差異：

| 規劃 | 現況 | 原因 |
|---|---|---|
| entrypoint 無 `apk add` | 有 `apk add --no-cache curl -q` | deploy hook 需要 curl 打 docker socket |
| hook 路徑 `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` | `/opt/scripts/deploy-hook.sh` | 原路徑是疊在 `/etc/letsencrypt` 內的巢狀單檔掛載，最易錯亂 |
| 單檔掛載 `./scripts/deploy-hook.sh:...` | 目錄掛載 `./scripts:/opt/scripts:ro` | 單檔 bind mount 在 Docker Desktop/WSL2 重啟後 `exit 127` |
| 掛 `docker-compose.yml` 進容器 | 已移除 | 用不到（commit `1296ec2`） |
| 無 healthcheck | 有（檢查 hook 與 curl 皆在） | 目錄掛載失效是「靜默掛空」，需要 healthcheck 才看得見 |

```yaml
# 當時的規劃（僅供對照，非現況）
certbot:
  image: certbot/certbot
  entrypoint: /bin/sh -c "trap exit TERM; while :; do certbot renew --deploy-hook /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh; sleep 12h & wait $${!}; done"
  volumes:
    - ./nginx/certs:/etc/letsencrypt
    - ./nginx/www:/var/www/certbot
    - ./scripts/deploy-hook.sh:/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh:ro
    - /var/run/docker.sock:/var/run/docker.sock:ro
  depends_on:
    - nginx
  restart: unless-stopped
```

### 新增檔案

- `scripts/deploy-hook.sh` — 透過 Docker socket 發送 SIGHUP 給 nginx container，觸發 graceful reload

## Done When（驗收條件）

以下條件均為二元可驗證（Pass / Fail）：

- [x] **D1** `docker compose ps certbot` 輸出狀態為 `running`（非 `exited` 或 `restarting`）
- [ ] **D2** `docker compose logs certbot` 顯示 certbot renew 執行記錄，且日誌間隔約 12 小時出現一次（或顯示 "not yet due" 後進入 sleep）
- [x] **D3** `make cert-status` 指令可用且輸出憑證到期日（不報 `make: *** No rule to make target` 錯誤）
- [x] **D4** `make cert-renew` 指令可用且執行後 certbot logs 顯示 renewal 嘗試記錄
- [ ] **D5** `certbot renew --dry-run`（在 certbot container 內執行）回傳 exit code 0，確認 ACME challenge 路由與 webroot 設定正確
- [x] **D6** 模擬 deploy hook（`docker compose exec certbot sh /opt/scripts/deploy-hook.sh`）執行後，`docker compose logs nginx` 顯示 `signal 1 (SIGHUP) received, reconfiguring`，且 HTTPS 服務不中斷（2026-09-10 實測，執行前後 origin 皆 200）

> 註：D6 原本寫的驗證路徑 `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` 已隨掛載方式改變而失效，照舊路徑跑會得到 file-not-found 而被誤判為「hook 壞了」。

## 風險

- **Docker socket 掛載安全性**：將 `/var/run/docker.sock` 掛載進 certbot container，等同給予該 container root 等級的 Docker 控制權。若 certbot image 或 deploy hook 腳本遭供應鏈攻擊，攻擊者可控制主機上所有 container。緩解措施：僅掛載 socket 為唯讀（`:ro`）、定期更新 certbot image（`docker compose pull certbot`），並限制 deploy hook 腳本僅執行 SIGHUP 操作。
- **Container 命名依賴**：deploy hook 以硬編碼的 container 名稱（`outline-docker-nginx-1`）發送 SIGHUP。若 docker compose 專案名稱變更，hook 將失效。緩解措施：在部署後以 D6 條件驗證 hook 是否正常運作。
- **Nginx www volume 寫入權限**：certbot 需要對 `/var/www/certbot` 具備寫入權限以完成 ACME challenge。若 nginx 掛載該路徑為 `:ro`，需確認移除唯讀限制，否則 dry-run 將失敗。

## 參考資料

- [docs/plans/2026-05-10-certbot-auto-renew.md](../plans/2026-05-10-certbot-auto-renew.md) — 詳細實作計劃
- [Let's Encrypt 文件：Certbot renew](https://certbot.eff.org/docs/using.html#renewing-certificates)
- [Docker Hub: certbot/certbot](https://hub.docker.com/r/certbot/certbot)
