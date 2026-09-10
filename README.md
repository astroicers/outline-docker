# Outline Wiki + Keycloak Docker 部署

一鍵部署 Outline Wiki v1.4 搭配 Keycloak 身份驗證，支援自訂用戶管理。

## 特色

- **Outline Wiki v1.4** - 現代化團隊知識庫
- **Keycloak** - 自建身份驗證，支援任意 Email 登入
- **自動 SSL** - Let's Encrypt 憑證
- **一鍵部署** - 互動式安裝腳本

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
docker compose up -d postgres redis nginx

# 建立 Keycloak 資料庫
docker compose exec postgres createdb -U outline keycloak

# 取得 SSL 憑證（將網域和 Email 換成你的）
docker run --rm \
  -v $(pwd)/nginx/certs:/etc/letsencrypt \
  -v $(pwd)/nginx/www:/var/www/certbot \
  certbot/certbot certonly --webroot \
  -w /var/www/certbot \
  -d wiki.example.com -d auth.example.com \
  --email your@email.com --agree-tos --non-interactive
```

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
docker compose exec postgres pg_dump -U outline outline > outline-backup.sql
docker compose exec postgres pg_dump -U outline keycloak > keycloak-backup.sql

# 上傳的檔案
tar -czvf data-backup.tar.gz data/

# 環境變數
cp .env .env.backup
```

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

Let's Encrypt 憑證 90 天到期：

```bash
# 手動更新
docker run --rm \
  -v $(pwd)/nginx/certs:/etc/letsencrypt \
  -v $(pwd)/nginx/www:/var/www/certbot \
  certbot/certbot renew

# 重載 Nginx
docker compose exec nginx nginx -s reload
```

**自動更新**（待實作）：計劃改用 Docker service 方式定期自動更新，取代 crontab 方案。詳見 [`docs/plans/2026-05-10-certbot-auto-renew.md`](docs/plans/2026-05-10-certbot-auto-renew.md)。

## 目錄結構

```
outline-docker/
├── docker-compose.yml        # 服務定義
├── .env                      # 環境變數（敏感）
├── .env.example              # 環境變數範例
├── .ai_profile               # AI 助手專案設定檔
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
│   │   └── 2026-05-10-certbot-auto-renewal.md   # certbot 自動更新規格
│   └── plans/                # 實作計劃文件
│       └── 2026-05-10-certbot-auto-renew.md     # certbot 自動更新實作計劃
├── data/                     # Outline 檔案儲存
├── keycloak/
│   └── import/               # 目錄掛載至 Keycloak 的 import
│       └── outline-realm.json    # Keycloak Realm 設定
├── nginx/
│   ├── templates/            # Nginx 設定模板
│   │   ├── outline.conf.template
│   │   └── outline-temp.conf.template
│   ├── conf.d/               # 執行時設定（由 setup.sh 生成）
│   │   └── outline.conf
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

**症狀**：網站回 525 或 SSL handshake failed，但憑證明明沒過期；
`docker compose ps` 顯示 postgres / keycloak / certbot `Exited (127)`，
nginx 卻是 running；`docker compose exec nginx nginx -t` 還會通過。

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

### 權限問題

```bash
chmod 777 data/
```

## 授權

MIT License
