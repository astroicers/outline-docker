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
| Shell 腳本語法 | ShellCheck | 檢查 setup.sh 語法和最佳實踐 |
| YAML 格式 | yamllint | 驗證 docker-compose.yml 格式 |
| JSON 格式 | jq | 驗證 Keycloak 設定檔 |
| Nginx 設定 | nginx -t | 驗證設定模板語法 |
| Docker Compose | docker compose config | 確認可解析 |

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

## 風險

- 驗證工具需要在本機和 CI 都能執行
- 未來新增檔案需要記得加入驗證範圍
