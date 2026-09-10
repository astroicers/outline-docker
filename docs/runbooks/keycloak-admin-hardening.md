# Runbook：Keycloak 管理員帳號加固（具名帳號 + OTP）

> **狀態**：待執行
> **對象**：`master` realm 的管理員帳號
> **停機**：無。全程不影響 wiki 與 SSO 登入。
> **預估時間**：25–35 分鐘（含驗證）
> **前置**：`master` realm 的暴力破解防護已於 2026-09-10 開啟（`failureFactor=5`、
> `permanentLockout=false`）。本 runbook 是同一批加固的剩餘部分。

## 為什麼要做

現況（2026-09-10 實測）：

- `master` realm 只有一個使用者 `admin`，具備 `admin` 與 `create-realm` 角色
- `https://<auth-domain>/admin` **公網可達**
- 帳號名 `admin` 可猜，且**沒有第二因素**

密碼本身是 `openssl rand -hex 32`（64 字元）猜不到，所以立即風險不高。
但整道防線只剩「密碼強度」這一項；受害的是**身分**而不是內容——攻擊者拿到之後
可以幫自己簽發任意使用者的 token，而不只是讀到 wiki 內容。

## ⚠ 執行前必讀：一個會讓你失去 CLI 管理能力的陷阱

**先做 Phase 1，不要跳過。**

實測確認兩件事：

1. `kcadm.sh config credentials` **沒有 `--otp` 選項**——它只支援
   `--user/--password`、`--client/--secret`（service account）、`--keystore`（signed JWT）。
2. `master` realm 的 direct grant flow 含 `Direct Grant - Conditional OTP`（CONDITIONAL），
   條件是 `Condition - user configured`（REQUIRED）。

```bash
# 自行複驗
docker compose exec -T keycloak sh -c \
  '/opt/keycloak/bin/kcadm.sh get authentication/flows/direct%20grant/executions -r master --fields displayName,requirement'
```

合起來：**一旦某個帳號設定了 OTP，該帳號的 `kcadm --user/--password` 登入就永久失效。**
若你先開 OTP 再想建 service account，就會發現自己已經沒有 CLI 可用了。

---

## Phase 0：前置與退路

```bash
cd ~/outline-docker

# 1. 備份（本 runbook 全程只改 Keycloak 的資料，這份備份就是最終退路）
make backup
tail -5 keycloak-backup.sql | grep -q "dump complete" && echo "備份完整" || echo "備份有問題，停止"

# 2. 確認目前 admin 可登入（基準線）
docker compose exec -T keycloak sh -c \
  '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
     --realm master --user admin --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1 \
   && echo "admin 登入正常" || echo "admin 登入失敗，先處理這個"'
```

**Break-glass（真的被鎖在外面時）**：Keycloak 26 提供
`docker compose exec keycloak /opt/keycloak/bin/kc.sh bootstrap-admin user`，
可在容器內直接建立一個新的管理員。這條路不需要既有的登入憑證，
所以**只要容器還起得來，你就不會永久失去管理權**。執行後需重啟 keycloak。

---

## Phase 1：先建立 CLI 專用的 service account

這一步讓自動化與 CLI 不再依賴任何人類帳號，也讓 Phase 3 開 OTP 之後你仍有 CLI 可用。

```bash
docker compose exec -T keycloak sh
```

進入容器後：

```sh
kc() { /opt/keycloak/bin/kcadm.sh "$@"; }
kc config credentials --server http://localhost:8080 --realm master \
   --user admin --password "$KEYCLOAK_ADMIN_PASSWORD"

# 建立 confidential client，只啟用 service account（不做互動式登入）
kc create clients -r master \
  -s clientId=ops-cli \
  -s enabled=true \
  -s publicClient=false \
  -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false \
  -s directAccessGrantsEnabled=false \
  -s 'description=CLI / 自動化專用，不綁任何人類帳號'

CID=$(kc get clients -r master -q clientId=ops-cli --fields id --format csv --noquotes | head -1)

# 給它管理權限（master realm 的 admin 角色）
kc add-roles -r master --uusername "service-account-ops-cli" --rolename admin

# 取出 secret（下一步要存起來）
kc get "clients/$CID/client-secret" -r master --fields value
exit
```

把上一步印出的 secret 存到 **repo 之外**（與 `~/.outline-docker-pg-superuser` 同樣做法）：

```bash
umask 077
cat > ~/.outline-docker-kc-cli <<'EOF'
# Keycloak master realm 的 CLI service account
# 用法見 docs/runbooks/keycloak-admin-hardening.md
KC_CLI_CLIENT=ops-cli
KC_CLI_CLIENT_SECRET=<貼上剛才那個 value>
EOF
chmod 600 ~/.outline-docker-kc-cli
```

**驗證（沒過就不要往下走）**：

```bash
SECRET=$(grep '^KC_CLI_CLIENT_SECRET=' ~/.outline-docker-kc-cli | cut -d= -f2-)
docker compose exec -T -e S="$SECRET" keycloak sh -c '
  /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
    --realm master --client ops-cli --secret "$S" >/dev/null 2>&1 \
  && /opt/keycloak/bin/kcadm.sh get users -r master --fields username \
  || echo "service account 登入失敗"'
```

能列出使用者，就代表 CLI 管理能力已經與人類帳號脫鉤。

---

## Phase 2：建立具名管理員（**新建，不要改名**）

不用「改名」而用「新建 + 停用舊的」，理由是**保留退路**：
改名是原地操作，Phase 3 的 OTP 註冊一旦出問題，你手上就沒有可用帳號了。

把 `harry` 換成你要的帳號名（建議用真人可辨識的名字，不要再用 `admin`）：

```bash
docker compose exec -T keycloak sh
```

```sh
kc() { /opt/keycloak/bin/kcadm.sh "$@"; }
kc config credentials --server http://localhost:8080 --realm master \
   --user admin --password "$KEYCLOAK_ADMIN_PASSWORD"

NEWADMIN=harry

kc create users -r master \
  -s username="$NEWADMIN" \
  -s enabled=true \
  -s emailVerified=true \
  -s email="你的email@example.com"

# 設一組強密碼（temporary=false：不強制首次登入更改，因為下一步就要綁 OTP）
kc set-password -r master --username "$NEWADMIN" --new-password "$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
# ↑ 上面這行會直接產生並套用隨機密碼但不顯示。若要自己指定，改用：
#   kc set-password -r master --username "$NEWADMIN" --new-password '你的密碼'

kc add-roles -r master --uusername "$NEWADMIN" --rolename admin --rolename create-realm

kc get-roles -r master --uusername "$NEWADMIN" --effective --fields name
exit
```

> 若用了上面那行隨機密碼，記得改用自己指定的密碼——否則你不知道密碼是什麼。
> **建議直接用自己指定的版本**，並把密碼存進密碼管理器（不要存進 `.env`）。

**驗證**：用瀏覽器（建議開無痕視窗，避免既有 session 干擾）登入
`https://<auth-domain>/admin`，以 `harry` 登入，確認看得到左側的 realm 清單與 Users 選單。

**這一步結束時，舊的 `admin` 仍然是啟用的**——那是你的退路，先不要動。

---

## Phase 3：為新管理員啟用 OTP

```bash
docker compose exec -T keycloak sh -c '
/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
  --realm master --user admin --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1
/opt/keycloak/bin/kcadm.sh update users/$(/opt/keycloak/bin/kcadm.sh get users -r master \
  -q username=harry --fields id --format csv --noquotes | head -1) \
  -r master -s "requiredActions=[\"CONFIGURE_TOTP\"]"'
```

然後**用瀏覽器**以 `harry` 登入 `https://<auth-domain>/admin`：

1. 登入後 Keycloak 會直接跳出 OTP 設定頁與 QR code
2. 用驗證器 App 掃描（master realm 的 OTP 政策是標準 TOTP：
   HmacSHA1 / 6 位數 / 30 秒週期，Google Authenticator、Authy、1Password、
   Bitwarden 都相容）
3. 輸入 App 顯示的 6 位數完成綁定
4. **把驗證器的備份機制設好**（1Password/Bitwarden 會自動同步；
   Google Authenticator 記得開雲端備份）——Keycloak 26 預設沒有 recovery code

**驗證（關鍵，沒過就不要進 Phase 4）**：

```
登出 → 重新登入 harry → 應該要求輸入 OTP → 輸入後成功進入 console
```

同時確認 CLI 仍可用（這時 `harry` 的 kcadm 密碼登入已經失效，走 service account）：

```bash
SECRET=$(grep '^KC_CLI_CLIENT_SECRET=' ~/.outline-docker-kc-cli | cut -d= -f2-)
docker compose exec -T -e S="$SECRET" keycloak sh -c '
  /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
    --realm master --client ops-cli --secret "$S" >/dev/null 2>&1 \
  && echo "CLI 仍可用"'
```

---

## Phase 4：停用（不是刪除）舊的 `admin`

**只有在 Phase 3 的兩項驗證都通過之後才做這一步。**

用「停用」而非「刪除」，因為停用可逆、刪除不可逆；而且保留該帳號的稽核記錄。

```bash
SECRET=$(grep '^KC_CLI_CLIENT_SECRET=' ~/.outline-docker-kc-cli | cut -d= -f2-)
docker compose exec -T -e S="$SECRET" keycloak sh -c '
/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
  --realm master --client ops-cli --secret "$S" >/dev/null 2>&1
AID=$(/opt/keycloak/bin/kcadm.sh get users -r master -q username=admin \
      --fields id --format csv --noquotes | head -1)
/opt/keycloak/bin/kcadm.sh update "users/$AID" -r master -s enabled=false
/opt/keycloak/bin/kcadm.sh get users -r master --fields username,enabled'
```

預期輸出：`admin` 的 `enabled` 為 `false`，`harry` 為 `true`。

**立即驗證**：用無痕視窗嘗試以 `admin` + 舊密碼登入，應該被拒絕；
以 `harry` + OTP 登入，應該成功。

---

## Phase 5：收尾

### 5.1 `.env` 裡的舊密碼

`KEYCLOAK_ADMIN_PASSWORD` 現在指向一個已停用的帳號。**先不要刪**——
`docker-compose.yml:52-53` 仍在引用它，刪掉會讓 `docker compose config` 失敗。
在 `.env` 該行上方加一行註解說明它已失效即可：

```bash
# 這組憑證對應的 admin 帳號已於 <日期> 停用，見 docs/runbooks/keycloak-admin-hardening.md
```

### 5.2 全新部署的行為（重要）

`docker-compose.yml:52` 的 `KEYCLOAK_ADMIN: admin` 只在**資料庫是空的**時候才會建立帳號。
所以：

- 現有部署：重啟不會把 `admin` 復活（它已存在於 DB，只是被停用）
- **全新部署 / 砍掉 `postgres-data` volume 重建**：會重新建出一個啟用的 `admin`，
  也就是回到加固前的狀態。屆時需要重跑本 runbook。

若要根治，Keycloak 26 提供 `kc.sh bootstrap-admin user|service` 作為取代環境變數的做法
（實測該指令存在於 26.0.8）。但改用它會讓「刪掉 volume 就能一鍵重建」這個特性失效，
需要在災難復原流程裡補一步手動 bootstrap。**這是取捨，不是純粹的改進**，
要不要做請另行決定。

### 5.3 更新文件

- 在 `README.md` 的「用戶管理 → Keycloak 管理後台」段落，把「使用 setup.sh 產生的
  admin 密碼登入」改成新的具名帳號與 OTP 流程
- `scripts/setup.sh:236` 印出的提示同步調整

---

## 驗收清單

全部打勾才算完成：

| # | 條件 | 驗證方式 |
|---|------|----------|
| 1 | service account 可用 | `kcadm --client ops-cli --secret ...` 能列出 users |
| 2 | 新管理員有 admin 與 create-realm 角色 | `kcadm get-roles --uusername <新帳號> --effective` |
| 3 | 新管理員登入需要 OTP | 無痕視窗登入，確實被要求輸入 6 位數 |
| 4 | 驗證器已備份 | 1Password/Bitwarden 已同步，或 Google Authenticator 雲端備份已開 |
| 5 | 舊 `admin` 已停用 | `kcadm get users --fields username,enabled` 顯示 `false` |
| 6 | 舊 `admin` 無法登入 | 無痕視窗以舊憑證登入被拒 |
| 7 | wiki 的 SSO 登入未受影響 | 登出 wiki 再登入一次，走完整 OIDC 流程 |
| 8 | `make doctor` 全綠 | `make doctor` |

> 第 7 項容易被忽略但很重要：本 runbook 動的是 `master` realm，
> 而 wiki 的使用者在 `outline` realm，兩者互不影響——但還是要實際走一次才算數。

---

## 回滾

| 情境 | 處置 |
|---|---|
| Phase 2 建的帳號有問題 | 舊 `admin` 仍啟用，直接用它刪掉新帳號重來 |
| Phase 3 OTP 綁定失敗／驗證器遺失 | 舊 `admin` 仍啟用，用它移除新帳號的 OTP credential 後重綁 |
| Phase 4 之後被完全鎖在外面 | `docker compose exec keycloak /opt/keycloak/bin/kc.sh bootstrap-admin user` 建新管理員，再重啟 keycloak |
| 上述都失敗 | 用 Phase 0 的 `keycloak-backup.sql` 還原（見 README「備份與還原」） |
