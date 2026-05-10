# [ADR-001]: 初始技術棧選型

| 欄位 | 內容 |
|------|------|
| **狀態** | `Accepted` |
| **日期** | 2026-05-10 |
| **決策者** | astroicers |

---

## 背景（Context）

需要一套可自建、完整掌控用戶管理的 Wiki 系統，供內部團隊使用。核心需求如下：

1. **不依賴第三方 OAuth**：Google OAuth 等外部服務會造成帳號管理與存取控制的限制，必須自建 identity provider。
2. **容器化部署**：以 Docker Compose 管理所有服務，降低環境差異風險、便於備份與遷移。
3. **HTTPS 加密**：對外暴露的端點必須有 TLS 加密，且憑證管理須自動化（不依賴手動更新）。
4. **開源、可自架**：避免 SaaS 鎖定風險，所有元件均為開源授權。

現有環境：一台 Linux VPS，有固定 IP 與網域，已安裝 Docker。

---

## 評估選項（Options Considered）

### 選項 A：Outline + Keycloak + Nginx + PostgreSQL + Redis + Let's Encrypt（本方案）

- **優點**：Outline 原生支援 OIDC，與 Keycloak 整合無需客製；Keycloak 提供完整的用戶管理 UI；Nginx alpine 輕量，webroot certbot 模式成熟穩定；PostgreSQL 同時服務 Outline 和 Keycloak，減少一個資料庫服務。
- **缺點**：初始設定步驟較多（需依序啟動服務、申請憑證、切換 Nginx 設定）；Keycloak 為 Java 應用，記憶體佔用較高（約 512MB–1GB）。
- **風險**：Let's Encrypt 憑證 90 天到期，若自動續期失敗會造成服務中斷。

### 選項 B：Outline + Google OAuth + Nginx + PostgreSQL + Redis

- **優點**：設定較簡單，不需要維護 Keycloak。
- **缺點**：用戶帳號綁定 Google 帳號，無法獨立管理；若組織 Google Workspace 帳號變動，存取控制難以精準控制。
- **風險**：對 Google 服務可用性與政策有依賴。

### 選項 C：Confluence / Notion 等 SaaS Wiki

- **優點**：零維運成本。
- **缺點**：月費持續支出；資料存放於第三方；無法完整掌控存取控制與資料主權。
- **風險**：SaaS 鎖定，服務終止或漲價時遷移困難。

---

## 決策（Decision）

我們選擇 **選項 A**（Outline + Keycloak + Nginx + PostgreSQL + Redis + Let's Encrypt），因為它同時滿足自建 IdP、容器化、自動化 SSL 三項核心需求，且所有元件均有穩定的 Docker image，可完整以 Docker Compose 管理。

具體版本選型：

| 元件 | 版本 | Docker Image |
|------|------|-------------|
| Outline Wiki | 1.4 | `outlinewiki/outline:1.4` |
| Keycloak | 26.0 | `quay.io/keycloak/keycloak:26.0` |
| Nginx | alpine | `nginx:alpine` |
| PostgreSQL | 15 | `postgres:15` |
| Redis | 7 | `redis:7` |
| Certbot | latest | `certbot/certbot` |

架構：Internet → Nginx (80/443) → Outline (3000) / Keycloak (8080) → PostgreSQL + Redis

PostgreSQL 單一 instance 同時服務兩個資料庫（`outline` 和 `keycloak`），以 `init-keycloak-db.sql` 初始化腳本建立 Keycloak 用的 DB，降低服務數量。

---

## 後果（Consequences）

**正面影響：**
- 完整掌控用戶帳號：所有帳號建立、停用、權限設定均在 Keycloak 管理，不依賴外部服務。
- 自動化 SSL：certbot webroot 模式搭配 cron，憑證到期前自動續期。
- 容器隔離：各服務以 Docker network 隔離，僅 Nginx 暴露 80/443，降低攻擊面。
- 輕量反向代理：Nginx alpine image 約 20MB，資源佔用極低。

**負面影響 / 技術債：**
- Keycloak 記憶體需求高，需確保 VPS 有足夠 RAM（建議 ≥ 2GB）。
- 初始設定步驟較多，需依序執行：啟動 DB → 初始化 Keycloak DB → 申請 SSL → 切換 Nginx 設定 → 啟動全部服務。
- Let's Encrypt 憑證 90 天到期，需監控續期狀態，避免服務中斷。
- PostgreSQL 共用單一 instance，若一個服務的查詢壓力過大可能影響另一個服務。

**後續追蹤：**
- [ ] 設定 certbot 自動續期 cron job（`0 3 * * * certbot renew --quiet`）
- [ ] 設定 PostgreSQL 備份排程（`make backup` 或 pg_dump cron）
- [ ] 監控 Keycloak 記憶體使用，超過 1GB 時評估是否需要升級 VPS
- [ ] 評估 Keycloak Realm 設定版本控制（outline-realm.json 納入 git）

---

## 成功指標（Success Metrics）

| 指標 | 目標值 | 驗證方式 | 檢查時間 |
|------|--------|----------|----------|
| 所有服務正常啟動 | 5 個容器均為 `Up` 狀態 | `docker compose ps` | 部署完成時 |
| Outline Wiki 可登入 | OIDC 登入流程成功，首位使用者成為管理員 | 瀏覽器登入測試 | 部署完成時 |
| SSL 憑證有效 | 憑證有效期 ≥ 60 天，瀏覽器無警告 | `openssl s_client -connect wiki.example.com:443` | 部署完成時 |
| HTTPS 強制跳轉 | HTTP 80 自動 301 到 HTTPS 443 | `curl -I http://wiki.example.com` | 部署完成時 |
| 憑證自動續期 | 90 天內自動完成 `certbot renew` | `certbot renew --dry-run` 回傳成功 | 每月檢查 |
| PostgreSQL 健康檢查 | `pg_isready` 回應時間 < 5 秒 | `docker compose ps`（healthcheck 狀態） | 持續監控 |
| 資料持久化 | 重啟後 Wiki 文件與使用者資料不遺失 | `docker compose down && docker compose up -d` | 首次部署後 |

> 重新評估此決策的情境：若 Keycloak 持續佔用超過 1.5GB RAM 導致其他服務不穩定，或 Outline 升版後不再相容目前的 OIDC 設定，應重新評估技術棧。

---

## 關聯（Relations）

- 取代：（無）
- 被取代：（無）
- 參考：
  - [Outline OIDC 文件](https://docs.getoutline.com/s/hosting/doc/oidc-8CPFhTRBCi)
  - [Keycloak Docker 部署指南](https://www.keycloak.org/server/containers)
  - [Let's Encrypt Certbot webroot 模式](https://certbot.eff.org/instructions)
  - `docker-compose.yml` — 服務定義與版本
  - `scripts/setup.sh` — 互動式設定腳本
