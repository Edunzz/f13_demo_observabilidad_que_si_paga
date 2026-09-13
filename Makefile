.PHONY: help build up down restart logs ps config smoke-test lint fmt-check clean diagnostics reset

# Makefile de conveniencia. La mayoria de estos targets se ejecutan [VM f13demo]
# (o localmente si tienes Docker Desktop). Los targets de infraestructura Azure
# viven en infra/azure/*.sh y scripts/*.sh, no aqui.

help: ## Muestra esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build: ## Construye todas las imagenes locales (docker compose build --pull)
	docker compose build --pull

up: ## Levanta el stack completo en background
	docker compose up -d

down: ## Detiene y elimina los contenedores (conserva volumenes)
	docker compose down

restart: ## Reinicia todos los servicios
	docker compose restart

logs: ## Sigue los logs de todos los servicios
	docker compose logs -f --tail=200

ps: ## Muestra el estado de los contenedores
	docker compose ps

config: ## Valida compose.yaml sin levantar nada
	docker compose config --quiet && echo "compose.yaml OK"

smoke-test: ## Ejecuta scripts/smoke-test.sh
	bash scripts/smoke-test.sh

lint: ## Corre shellcheck sobre todos los scripts bash (requiere shellcheck instalado)
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck no esta instalado, ver docs/08-troubleshooting.md"; exit 1; }
	shellcheck infra/azure/*.sh scripts/*.sh scripts/lib/*.sh

diagnostics: ## Recolecta diagnostico local (requiere VM accesible por SSH)
	bash scripts/collect-diagnostics.sh

reset: ## recover + reset del acumulador financiero + smoke test
	bash scripts/demo-reset.sh
