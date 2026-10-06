.PHONY: help up down restart logs ps status urls smoke-test fault recover reset snapshot test config lint diagnostics clean

# Makefile de conveniencia. Todos los targets corren en el Codespace (o en
# cualquier entorno que haya abierto el devcontainer del repo) y delegan en
# scripts/*.sh, que son la fuente de verdad.

SERVICES_WITH_TESTS := shop-api payment-service value-exporter load-generator

help: ## Muestra esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

up: ## Levanta el laboratorio completo (setup .env + build + up + healthchecks + smoke test)
	bash scripts/lab-up.sh

down: ## Detiene y elimina los contenedores (conserva volumenes)
	docker compose down

restart: ## Reinicia todos los servicios
	docker compose restart

logs: ## Sigue los logs de todos los servicios
	docker compose logs -f --tail=200

ps: ## Muestra el estado de los contenedores
	docker compose ps

status: ## Contenedores + estado de la falla + URLs
	bash scripts/status.sh

urls: ## Imprime las URLs del laboratorio (Codespaces o localhost)
	bash scripts/show-urls.sh

smoke-test: ## Ejecuta scripts/smoke-test.sh
	bash scripts/smoke-test.sh

fault: ## Inyecta la falla en payment-service (1800 ms / 30 % de error) sin confirmar
	bash scripts/inject-fault.sh --yes

recover: ## Desactiva la falla sin reiniciar el stack
	bash scripts/recover.sh

reset: ## recover + reset del acumulador financiero + smoke test
	bash scripts/demo-reset.sh

snapshot: ## Senales tecnicas, SLO y capa de valor en la terminal
	bash scripts/business-snapshot.sh

test: ## Corre las pruebas unitarias de cada app en su propio venv (.venv-<app>)
	@set -e; for svc in $(SERVICES_WITH_TESTS); do \
		echo "== $$svc =="; \
		python3 -m venv .venv-$$svc; \
		.venv-$$svc/bin/pip install -q -r app/$$svc/requirements.txt; \
		(cd app/$$svc && ../../.venv-$$svc/bin/python -m pytest -q); \
	done

config: ## Valida compose.yaml sin levantar nada
	docker compose config --quiet && echo "compose.yaml OK"

lint: ## Corre shellcheck sobre todos los scripts bash (requiere shellcheck instalado)
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck no esta instalado: pip install shellcheck-py"; exit 1; }
	shellcheck -x -P SCRIPTDIR scripts/*.sh scripts/lib/*.sh

diagnostics: ## Empaqueta diagnostico (ps, logs, config sanitizada) en diagnostics/
	bash scripts/collect-diagnostics.sh

clean: ## Detiene el stack y BORRA sus volumenes (metricas, trazas, Grafana)
	docker compose down -v
