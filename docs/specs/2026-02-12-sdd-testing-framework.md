# SDD 開發流程與推版前測試框架

## 背景

outline-docker 專案目前沒有任何測試或 CI/CD 設定。為了確保變更品質並建立可維護的開發流程，需要引入 SDD (Spec-Driven Development) 開發流程和自動化測試。

## 目標

1. 建立 SDD 開發流程，確保變更有明確規格
2. 實作快速驗證腳本，在推版前自動檢查
3. 設定 GitHub Actions CI/CD，自動執行驗證

## 方案

### 目錄結構

```
outline-docker/
├── docs/
│   └── specs/                    # SDD 規格文件
│       └── TEMPLATE.md           # 規格範本
├── scripts/
│   ├── setup.sh                  # (既有)
│   ├── init-keycloak-db.sql      # (既有)
│   └── validate.sh               # 新增：驗證腳本
├── .github/
│   └── workflows/
│       └── validate.yml          # GitHub Actions 工作流程
├── Makefile                      # 開發指令集
└── .shellcheckrc                 # ShellCheck 設定
```

### 驗證項目

| 驗證項目 | 工具 | 說明 |
|---------|------|------|
| Shell 腳本語法 | ShellCheck | 檢查 `scripts/*.sh` 語法和最佳實踐 |
| YAML 格式 | yamllint | 驗證 docker-compose.yml 格式 |
| JSON 格式 | jq | 驗證 Keycloak realm 範本與（若存在）實體檔 |
| 環境變數範本 | grep | 確認 `.env.example` 含所有必要變數 |
| Docker Compose | docker compose config | 確認可解析 |
| Nginx 設定 | `nginx -t`（容器內） | 真正跑一次語法檢查；早期版本只做 `grep -q "server {"` 的結構檢查，抓不到 conflicting server name 這類問題 |
| 必要檔案 | test -f | 確認關鍵檔案都在

預計執行時間：< 30 秒

### SDD 開發流程

```
1. 撰寫規格 → docs/specs/YYYY-MM-DD-<topic>.md
2. 規格審核 → PR review 或自行確認
3. 實作變更 → 根據規格修改程式碼
4. 執行驗證 → make validate
5. 提交 PR → CI 自動驗證
6. 合併 → 驗證通過後合併
```

### Makefile 指令

- `make validate` - 執行所有驗證 (推版前必跑)
- `make validate-quick` - 快速驗證 (不需 Docker)
- `make setup` - 執行互動式設定
- `make up` - 啟動所有服務
- `make down` - 停止服務
- `make logs` - 查看日誌

### GitHub Actions

觸發條件：
- Pull Request 到 main
- Push 到 main

工作流程：
1. Checkout 程式碼
2. 安裝工具 (shellcheck, yamllint, jq)
3. 執行 scripts/validate.sh
4. 報告結果

## 驗證方式

1. 執行 `make validate` 確認所有驗證通過
2. 提交 PR 確認 GitHub Actions 正常執行
3. 故意引入錯誤確認驗證能捕捉

## Done When（驗收條件）

以下條件全部為二元可驗證，標記 ✅ 表示已通過（功能已實作）。

| # | 驗收條件 | 驗證指令 | 狀態 |
|---|---------|---------|------|
| 1 | `make validate` 執行後 exit code 為 0，所有驗證通過 | `make validate; echo $?` | ✅ |
| 2 | `make validate-quick` 可執行且在 30 秒內完成 | `time make validate-quick` | ✅ |
| 3 | `.github/workflows/validate.yml` 存在，且 CI 設定在 PR 及 Push 到 main 時自動觸發 | `cat .github/workflows/validate.yml` | ✅ |
| 4 | 故意在 `docker-compose.yml` 引入 YAML 語法錯誤後，`make validate` 回傳 exit code 非 0 | 手動引入錯誤並執行 `make validate; echo $?` | ✅ |
| 5 | `make new-spec` 可執行，並在 `docs/specs/` 下建立以當日日期為前綴的新規格文件 | `make new-spec` | ✅ |
| 6 | `scripts/validate.sh` 存在且可執行（有 execute 權限） | `test -x scripts/validate.sh && echo ok` | ✅ |
| 7 | CI 工作流程包含 ShellCheck、yamllint、jq、Docker Compose config、必要檔案檢查、secrets 檢查、Nginx 模板驗證等 7 個驗證步驟（另有 Checkout 與 Install tools 兩步） | `grep -c '^      - name:' .github/workflows/validate.yml`（期望 9） | ✅ |
| 8 | `docs/specs/` 目錄存在，且有規格範本 `docs/specs/TEMPLATE.md` | `ls docs/specs/TEMPLATE.md` | ✅ |

## 風險

- 驗證工具需要在本機和 CI 都能執行
- 未來新增檔案需要記得加入驗證範圍
