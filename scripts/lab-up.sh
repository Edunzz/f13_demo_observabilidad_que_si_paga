#!/usr/bin/env bash
# Levanta el laboratorio F13 completo dentro del Codespace: prepara .env,
# construye las imágenes, arranca el stack, espera los healthchecks, corre el
# smoke test e imprime las URLs.
#
# Es el postStartCommand del devcontainer (.devcontainer/devcontainer.json):
# corre solo cada vez que el Codespace arranca. Es idempotente: si el stack ya
# está arriba, `docker compose up -d` no recrea nada que no haya cambiado.
#
# Uso:
#   bash scripts/lab-up.sh [--no-smoke] [-h|--help]
#
# Todo corre en HTTP plano: no hay TLS ni certificados en ningún servicio.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

HEALTH_TIMEOUT_SECONDS=300
RUN_SMOKE="true"

usage() {
    cat <<'EOF'
Uso: bash scripts/lab-up.sh [--no-smoke] [-h|--help]

Levanta el laboratorio F13 en este Codespace, en este orden:
  1. scripts/setup-env.sh (crea/completa .env y genera secretos)
  2. Espera al daemon de Docker (feature docker-in-docker)
  3. docker compose config --quiet
  4. docker compose up -d --build
  5. Espera los healthchecks de todos los contenedores (timeout 5 min)
  6. scripts/smoke-test.sh (se omite con --no-smoke)
  7. En Codespaces, publica los puertos web (scripts/publish-ports.sh) e
     imprime las URLs del laboratorio

Opciones:
  --no-smoke   no ejecuta el smoke test al final
  -h, --help   muestra esta ayuda
EOF
}

for arg in "$@"; do
    case "${arg}" in
        -h|--help)
            usage
            exit 0
            ;;
        --no-smoke)
            RUN_SMOKE="false"
            ;;
        *)
            log_error "Argumento no reconocido: ${arg}"
            usage
            exit 1
            ;;
    esac
done

require_cmd docker curl

log_info "Paso 1/7: preparando .env..."
bash "${SCRIPT_DIR}/setup-env.sh"

log_info "Paso 2/7: verificando Docker..."
wait_for_docker 120
if ! docker compose version >/dev/null 2>&1; then
    log_error "docker compose (plugin v2) no está disponible. ¿Abriste el repo con su devcontainer?"
    exit 1
fi

log_info "Paso 3/7: validando compose.yaml (docker compose config --quiet)..."
compose config --quiet

log_info "Paso 4/7: construyendo y levantando el stack (la primera vez tarda unos minutos)..."
compose up -d --build

log_info "Paso 5/7: esperando healthchecks (timeout ${HEALTH_TIMEOUT_SECONDS}s)..."
if ! wait_for_healthy "${HEALTH_TIMEOUT_SECONDS}" 5; then
    log_error "Revisa el estado con: docker compose ps   y los logs con: docker compose logs --tail=100 <servicio>"
    exit 1
fi
log_info "Todos los contenedores están healthy (o sin healthcheck por diseño)."

if [[ "${RUN_SMOKE}" == "true" ]]; then
    log_info "Paso 6/7: ejecutando smoke test..."
    bash "${SCRIPT_DIR}/smoke-test.sh"
else
    log_info "Paso 6/7: smoke test omitido (--no-smoke)."
fi

log_info "Paso 7/7: publicando puertos web e imprimiendo URLs..."
if in_codespace; then
    # No es fatal: si la organización bloquea puertos públicos, el
    # laboratorio sigue funcionando con puertos privados.
    bash "${SCRIPT_DIR}/publish-ports.sh" || log_warn "Los puertos quedaron privados (solo tu cuenta de GitHub puede abrirlos)."
fi
log_info "Laboratorio F13 listo."
echo
print_urls
echo
echo "Siguiente paso: sigue la 'Exploración guiada' del README.md."
echo "  bash scripts/business-snapshot.sh     # capa de valor en la terminal"
echo "  bash scripts/inject-fault.sh --yes     # rompe payment-service de forma controlada"
echo "  bash scripts/recover.sh                # recupera sin reiniciar nada"
