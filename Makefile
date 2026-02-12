# Outline Docker 專案 Makefile
# 使用方式: make <target>

.PHONY: help validate validate-quick setup up down restart logs ps backup

# 預設目標
help:
	@echo "Outline Docker 專案指令"
	@echo ""
	@echo "驗證指令:"
	@echo "  make validate       執行所有驗證 (推版前必跑)"
	@echo "  make validate-quick 快速驗證 (不需要 Docker)"
	@echo ""
	@echo "服務管理:"
	@echo "  make setup          執行互動式設定"
	@echo "  make up             啟動所有服務"
	@echo "  make down           停止所有服務"
	@echo "  make restart        重啟所有服務"
	@echo "  make ps             查看服務狀態"
	@echo "  make logs           查看日誌 (全部)"
	@echo "  make logs-outline   查看 Outline 日誌"
	@echo "  make logs-keycloak  查看 Keycloak 日誌"
	@echo "  make logs-nginx     查看 Nginx 日誌"
	@echo ""
	@echo "資料庫:"
	@echo "  make db-shell       進入 PostgreSQL shell"
	@echo "  make backup         備份資料庫"
	@echo ""
	@echo "開發:"
	@echo "  make new-spec       建立新的規格文件"

# ============================================
# 驗證指令
# ============================================

validate:
	@./scripts/validate.sh

validate-quick:
	@echo "快速驗證 (不需要 Docker)..."
	@command -v shellcheck > /dev/null && shellcheck scripts/*.sh || echo "shellcheck 未安裝，跳過"
	@command -v yamllint > /dev/null && yamllint -d "{extends: relaxed, rules: {line-length: disable}}" docker-compose.yml || echo "yamllint 未安裝，跳過"
	@command -v jq > /dev/null && [ -f keycloak/outline-realm.json ] && jq empty keycloak/outline-realm.json || true
	@echo "快速驗證完成"

# ============================================
# 服務管理
# ============================================

setup:
	@./scripts/setup.sh

up:
	docker compose up -d

down:
	docker compose down

restart:
	docker compose restart

ps:
	docker compose ps

logs:
	docker compose logs -f

logs-outline:
	docker compose logs -f outline

logs-keycloak:
	docker compose logs -f keycloak

logs-nginx:
	docker compose logs -f nginx

# ============================================
# 資料庫
# ============================================

db-shell:
	docker compose exec postgres psql -U outline

backup:
	@echo "備份 Outline 資料庫..."
	@docker compose exec postgres pg_dump -U outline outline > outline-backup.sql
	@echo "備份 Keycloak 資料庫..."
	@docker compose exec postgres pg_dump -U outline keycloak > keycloak-backup.sql
	@echo "備份完成: outline-backup.sql, keycloak-backup.sql"

# ============================================
# 開發
# ============================================

new-spec:
	@DATE=$$(date +%Y-%m-%d); \
	read -p "規格標題 (英文，用-連接): " TITLE; \
	FILENAME="docs/specs/$${DATE}-$${TITLE}.md"; \
	cp docs/specs/TEMPLATE.md "$$FILENAME"; \
	echo "已建立: $$FILENAME"; \
	echo "請編輯此檔案撰寫規格"
