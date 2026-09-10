# Outline Wiki + Keycloak Docker 部署

Outline Wiki v1.4 搭配 Keycloak 身份驗證的 Docker 部署，附互動式設定腳本與自動 SSL 續期。

## 特色

- **Outline Wiki v1.4** - 現代化團隊知識庫
- **Keycloak** - 自建身份驗證，支援任意 Email 登入
- **自動 SSL** - Let's Encrypt 憑證
- **互動式安裝腳本** - 產生設定檔並列出後續步驟
- **自動續期** - certbot service 每 12 小時檢查，更新後自動 reload nginx

## 架構

```
Internet → Nginx (80/443)
              ├── wiki.example.com → Outline (3000)
              └── auth.example.com → Keycloak (8080)
                          ↓
                    PostgreSQL + Redis
```

## 前置需求

- Docker 和 Docker Compose
- 兩個網域（例如 `wiki.example.com` 和 `auth.example.com`）
- 防火牆開放 port 80 和 443

## 快速開始

### 1. 下載專案

```bash
git clone https://github.com/你的帳號/outline-docker.git
cd outline-docker
```

### 2. 執行安裝腳本

```bash
./scripts/setup.sh
```

腳本會請你輸入：
- Wiki 網域（例如 `wiki.example.com`）
- Keycloak 網域（例如 `auth.example.com`）
- Email（用於 SSL 憑證）
- 用戶資訊（Email 和名稱）

### 3. 設定 DNS

將你的兩個網域指向伺服器 IP：
- `wiki.example.com` → 你的 IP
- `auth.example.com` → 你的 IP

### 4. 取得 SSL 憑證

```bash
# 啟動基礎服務
# （Keycloak 的資料庫由 scripts/initdb/init-keycloak-db.sql 在 postgres 首次
#   初始化時自動建立，不需要手動 createdb）
docker compose up -d postgres redis nginx

# 取得 SSL 憑證（將網域和 Email 換成你的）
docker run --rm \
  -v $(pwd)/nginx/certs:/etc/letsencrypt \
  -v $(pwd)/nginx/www:/var/www/certbot \
  -v $(pwd)/scripts:/opt/scripts:ro \
  certbot/certbot certonly --webroot \
  -w /var/www/certbot \
  -d wiki.example.com -d auth.example.com \
  --deploy-hook /opt/scripts/deploy-hook.sh \
  --email your@email.com --agree-tos --non-interactive
```

> `-v $(pwd)/scripts:/opt/scripts:ro` 與 `--deploy-hook` 兩行不可省略：
> 它們會把 reload hook 的路徑寫進 `/etc/letsencrypt/renewal/*.conf`，
> 之後續期才會自動 reload nginx。`setup.sh` 印出的指令與這裡一致。

### 5. 啟動所有服務

```bash
# 切換到 SSL 設定
cp nginx/conf.d/outline.conf.ssl nginx/conf.d/outline.conf

# 啟動所有服務
docker compose up -d
```

### 6. 完成！

訪問 `https://wiki.example.com`，使用 Keycloak 登入。

## 常用指令

本專案的日常操作建議走 Makefile：

```bash
make help          # 列出所有指令
make up            # 啟動所有服務
make down          # 停止服務
make ps            # 服務狀態
make logs          # 查看日誌
make doctor        # 健康診斷（掛載／TLS／憑證，唯讀）
make recover       # bind mount 失效時的修復入口（見故障排除）
make backup        # 備份兩個資料庫
make validate      # 推版前必跑
make cert-status   # 憑證狀態
```

底層的 docker compose 指令：

```bash
# 服務管理
docker compose up -d          # 啟動
docker compose down           # 停止
docker compose restart        # 重啟
docker compose ps             # 狀態

# 查看日誌
docker compose logs -f outline
docker compose logs -f keycloak
docker compose logs -f nginx

# 資料庫操作
docker compose exec postgres psql -U outline    # 進入 PostgreSQL
```

## 備份與還原

### 備份

```bash
# PostgreSQL（包含 Outline 和 Keycloak 資料）
# 注意 -T：沒有它 docker 會配置 TTY，備份內容會被加上 CRLF 而損壞
docker compose exec -T postgres pg_dump -U outline outline > outline-backup.sql
docker compose exec -T postgres pg_dump -U outline keycloak > keycloak-backup.sql

# 上傳的檔案
tar -czvf data-backup.tar.gz data/

# 環境變數（含全部密鑰，請 chmod 600 並存放在 repo 之外）
cp .env .env.backup && chmod 600 .env.backup
```

或直接用 `make backup`（涵蓋兩個資料庫）。

### 還原

```bash
cat outline-backup.sql | docker compose exec -T postgres psql -U outline outline
cat keycloak-backup.sql | docker compose exec -T postgres psql -U outline keycloak
tar -xzvf data-backup.tar.gz
```

## 用戶管理

### Keycloak 管理後台

訪問 `https://auth.example.com/admin`

使用 setup.sh 產生的 admin 密碼登入（在終端輸出中）。

### 新增用戶

1. 登入 Keycloak 管理後台
2. 選擇 Realm：`outline`
3. 左側選單 → Users → Add user
4. 填入 Email、名稱
5. Credentials 標籤設定密碼

### 修改用戶密碼

1. Users → 選擇用戶
2. Credentials 標籤
3. Reset password

## SSL 憑證更新

**自動續期已經在跑，正常情況下不需要做任何事。** `docker-compose.yml` 的 `certbot`
服務每 12 小時執行一次 `certbot renew`；Let's Encrypt 在到期前 30 天才會實際續期，
續期成功後由 [`scripts/deploy-hook.sh`](scripts/deploy-hook.sh) 對 nginx 送 SIGHUP
觸發 graceful reload，服務不中斷。

```bash
make cert-status        # 查看憑證與到期日
make cert-renew         # 手動觸發一次（未到期則不會動作）
make doctor             # 順帶檢查憑證是否即將到期、hook 是否還在
```

> 不要另外架 cron 或手動跑 `docker run ... certbot renew`。理由有兩個：
> 一是會變成第二套續期路徑，重複續期會撞上 Let's Encrypt 的速率限制；
> 二是那樣的 `docker run` 沒有掛 `/opt/scripts` 也沒有掛 docker socket，
> deploy hook 一定失敗——結果是**憑證換了但 nginx 一直送舊的**，
> 直到舊憑證過期才爆出 SSL 錯誤，中間毫無告警。

## 目錄結構

```
outline-docker/
├── docker-compose.yml        # 服務定義
├── .env                      # 環境變數（敏感）
├── .env.example              # 環境變數範例
├── .ai_profile               # AI 助手專案設定檔
├── .gitignore
├── .shellcheckrc             # ShellCheck 設定（影響 CI 判定結果）
├── CLAUDE.md                 # AI 助手工作指引
├── Makefile                  # 常用指令集
├── setup.sh                  # 互動式設定腳本（scripts/setup.sh 的捷徑）
├── scripts/
│   ├── setup.sh              # 安裝腳本
│   ├── validate.sh           # 驗證腳本（CI 與本機共用）
│   ├── doctor.sh             # 唯讀健康診斷（掛載／TLS／憑證）
│   ├── deploy-hook.sh        # certbot 更新後 reload nginx
│   └── initdb/               # 目錄掛載至 postgres 的 initdb
│       └── init-keycloak-db.sql  # Keycloak 資料庫初始化
├── docs/
│   ├── adr/                  # 架構決策記錄（ADR）
│   │   └── ADR-001-initial-technology-stack.md  # 初始技術棧選型決策
│   ├── specs/                # 功能規格文件（SDD）
│   │   ├── TEMPLATE.md                          # 新規格範本（make new-spec 用）
│   │   ├── 2026-02-12-sdd-testing-framework.md  # 驗證框架規格
│   │   └── 2026-05-10-certbot-auto-renewal.md   # certbot 自動更新規格
│   └── plans/                # 實作計劃文件
│       └── 2026-05-10-certbot-auto-renew.md     # certbot 自動更新實作計劃
├── data/                     # Outline 檔案儲存
├── keycloak/
│   └── import/               # 目錄掛載至 Keycloak 的 import
│       ├── outline-realm.json.template  # 版控中的範本（佔位值）
│       └── outline-realm.json           # setup.sh 生成，含真實密鑰，已 gitignore
├── nginx/
│   ├── templates/            # Nginx 設定模板
│   │   ├── outline.conf.template
│   │   └── outline-temp.conf.template
│   ├── conf.d/               # 執行時設定（由 setup.sh 生成，已 gitignore）
│   │   ├── outline.conf              # 目前生效的設定（nginx 只載入 *.conf）
│   │   ├── outline.conf.ssl          # SSL 版，步驟 5 複製成 outline.conf
│   │   └── outline-temp.conf.tmpl    # HTTP-only 版，副檔名刻意不是 .conf
│   ├── certs/                # SSL 憑證
│   └── www/                  # Let's Encrypt 驗證
└── .github/
    └── workflows/
        └── validate.yml      # CI 驗證工作流程
```

## 故障排除

### 先跑健康診斷

```bash
make doctor     # 唯讀：檢查掛載、TLS、憑證，並指出該做什麼
```

> 首次部署、憑證還沒簽下來之前，生效的是 HTTP-only 的暫時設定（只 `listen 80`），
> 此時 nginx 會顯示 **unhealthy**，`make doctor` 的 TLS 項目也會失敗——這是正常的。
> 換上 SSL 設定（安裝步驟 5）之後就會轉綠。

### 服務狀態檢查

```bash
docker compose ps
docker compose logs [服務名稱]
```

### SSL handshake failed / Cloudflare 525（Docker Desktop + WSL2）

**症狀**：網站回 525 或 SSL handshake failed，但憑證明明沒過期。
`docker compose ps` 的表現依版本而不同：

| | 表現 |
|---|---|
| **現行版本** | nginx / certbot 標為 `unhealthy`，其餘照常 running |
| **舊版本（單檔掛載時期）** | postgres / keycloak / certbot `Exited (127)` |

兩種情況下 `docker compose exec nginx nginx -t` 都會**通過**——因為根本沒有 config 可以失敗。

**成因**：Docker Desktop 的 WSL bind-mount 快取與 host inode 脫鉤（通常在
Docker Desktop 或 WSL 重啟後、或 host 端目錄被重建過之後）。它有兩種壞法：

| 掛載型態 | 結果 |
|---|---|
| 目錄 bind mount | **靜默**掛成空目錄，容器照常啟動 |
| 單檔 bind mount | 硬失敗 `exit 127`，容器起不來 |

nginx 屬於前者：`/etc/nginx/conf.d` 掛成空的 → 沒有任何 `listen 443 ssl`
server block → `nginx -t` 因為「沒有 config 可以失敗」而通過 → 443 收到連線後
立刻 EOF → CDN 判定 origin 握手失敗 → 525。

**確認方式**：

```bash
docker compose exec nginx ls -la /etc/nginx/conf.d/ /etc/letsencrypt/
# 掛載壞掉時這些會是空目錄（時間戳等於容器啟動時間）

curl -sSk -o /dev/null -w '%{http_code}\n' \
  --resolve wiki.example.com:443:127.0.0.1 https://wiki.example.com/
# 掛載壞掉時得到 000 + "unexpected eof while reading"
```

**處置**：

```bash
make recover     # docker compose down + up，重建容器以重新解析掛載
```

`docker compose restart` **救不了**——restart 沿用既有的容器與掛載命名空間，
必須 down/up 重建。若 `make recover` 後掛載仍是空的，代表 Docker Desktop 的
bind-mount 快取本身壞了，需在 Windows 端重啟 Docker Desktop 再跑一次。

> 本專案已把所有**專案檔案**的單檔 bind mount 改為目錄掛載（`scripts/initdb/`、
> `keycloak/import/`、`/opt/scripts`），消除 exit 127 那一類故障。
> `/var/run/docker.sock` 是刻意的例外——它由 Docker Desktop 提供，不走 WSL inode 快取。
>
> **要留意代價**：單檔掛載壞掉時會停機（exit 127），是個大聲的警報；改成目錄掛載後
> 同一個事件變成**安靜地掛空**。因此 nginx 與 certbot 都加了 healthcheck 把它變回可見
> （`docker compose ps` 顯示 unhealthy）。certbot 那條特別重要：它的 hook 掛空時，
> 憑證會照常更新但 nginx 永遠不 reload，繼續送舊憑證直到過期才爆同一個 525。
> healthcheck **只負責可見化，不會自動重啟**——看到 unhealthy 請跑 `make recover`。

### 無法連接網站

1. 確認 DNS 設定正確
2. 確認 port 80/443 已開放
3. 檢查 `docker compose logs nginx`

### Keycloak 登入失敗

```bash
docker compose logs keycloak
```

確認 Realm `outline` 已建立。

### 權限問題（上傳附件出現 EACCES）

Outline 容器以 **uid 1001** 執行，所以 `data/` 需要的是「uid 1001 可寫」，
不是「全世界可寫」：

```bash
sudo chown -R 1001:1001 data/ && chmod 755 data/
```

> 不要用 `chmod 777 data/`。那會讓主機上任何本地使用者、以及任何掛了同一路徑的
> 其他容器，都能讀寫全部使用者上傳的附件——包含把惡意檔案塞進去，
> 讓 Outline 之後當成合法附件提供下載。
> （`setup.sh` 在沒有 root 權限時仍會退回 777 並印出提醒，請事後補做上面這行。）

## 授權

MIT License
