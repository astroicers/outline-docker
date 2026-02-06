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
./setup.sh
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

建議設定 crontab 自動更新：

```bash
0 0 1 * * cd /path/to/outline-docker && docker run --rm -v $(pwd)/nginx/certs:/etc/letsencrypt -v $(pwd)/nginx/www:/var/www/certbot certbot/certbot renew && docker compose exec nginx nginx -s reload
```

## 目錄結構

```
outline-docker/
├── docker-compose.yml        # 服務定義
├── .env                      # 環境變數（敏感）
├── .env.example              # 環境變數範例
├── setup.sh                  # 安裝腳本
├── init-keycloak-db.sql      # Keycloak 資料庫初始化
├── data/                     # Outline 檔案儲存
├── keycloak/
│   └── outline-realm.json    # Keycloak Realm 設定
└── nginx/
    ├── certs/                # SSL 憑證
    ├── conf.d/
    │   ├── outline.conf      # Nginx 設定
    │   └── outline.conf.ssl  # SSL 設定範本
    └── www/                  # Let's Encrypt 驗證
```

## 故障排除

### 服務狀態檢查

```bash
docker compose ps
docker compose logs [服務名稱]
```

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
