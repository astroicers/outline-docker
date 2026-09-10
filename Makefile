# Outline Docker 專案 Makefile
# 使用方式: make <target>

.PHONY: help validate validate-quick setup up down restart logs ps backup doctor recover

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
	@echo "  make doctor         健康診斷（掛載／TLS／憑證，唯讀）"
	@echo "  make recover        重建容器修復失效的 bind mount，再跑 doctor"
	@echo "  make logs           查看日誌 (全部)"
	@echo "  make logs-outline   查看 Outline 日誌"
	@echo "  make logs-keycloak  查看 Keycloak 日誌"
	@echo "  make logs-nginx     查看 Nginx 日誌"
	@echo ""
	@echo "資料庫:"
	@echo "  make db-shell       進入 PostgreSQL shell"
	@echo "  make backup         備份資料庫"
	@echo ""
	@echo "SSL 憑證:"
	@echo "  make cert-renew     強制更新 SSL 憑證"
	@echo "  make cert-status    查看憑證狀態"
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
	@command -v jq > /dev/null && [ -f keycloak/import/outline-realm.json.template ] && jq empty keycloak/import/outline-realm.json.template || true
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

# Docker Desktop / WSL2 重啟後 bind mount 會失效（目錄靜默掛空、單檔 exit 127）。
# restart 救不了——必須重建容器才會重新解析到當前的 host inode。
recover:
	@echo "重建容器以修復失效的 bind mount..."
	docker compose down --remove-orphans
	docker compose up -d
	@echo "等待服務就緒..."
	@sleep 15
	@$(MAKE) --no-print-directory doctor

doctor:
	@./scripts/doctor.sh

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

# ============================================
# SSL 憑證
# ============================================

cert-renew:
	docker compose exec certbot certbot renew --force-renewal

cert-status:
	docker compose exec certbot certbot certificates

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
