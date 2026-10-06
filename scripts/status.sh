#!/usr/bin/env bash
# Muestra el estado del laboratorio F13 sin modificar nada: contenedores,
# estado de la falla inyectada y URLs.
#
# Uso:
#   bash scripts/status.sh [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

usage() {
    cat <<'EOF'
Uso: bash scripts/status.sh [-h|--help]

Solo lectura. Muestra:
  - `docker compose ps` (estado y salud de cada contenedor)
  - el estado actual de la falla de payment-service (GET /admin/fault)
  - las URLs del laboratorio (port forwarding de Codespaces o localhost)

Si el stack no está corriendo, sugiere `bash scripts/lab-up.sh`.
EOF
}

for arg in "$@"; do
    case "${arg}" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Argumento no reconocido: ${arg}"
            usage
            exit 1
            ;;
    esac
done

require_cmd docker curl

if ! docker info >/dev/null 2>&1; then
    log_error "El daemon de Docker no responde todavía. Espera unos segundos y reintenta."
    exit 1
fi

ps_output="$(compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}' 2>&1 || true)"
echo "== Contenedores del laboratorio =="
echo "${ps_output}"
echo

if ! grep -qiE 'running' <<<"${ps_output}"; then
    log_warn "No hay contenedores en ejecución. Levanta el laboratorio con: bash scripts/lab-up.sh"
    exit 1
fi
if grep -qiE 'unhealthy|restarting|starting' <<<"${ps_output}"; then
    log_warn "Hay contenedores que aún no están healthy. Si persiste: docker compose logs --tail=100 <servicio>"
fi

fault_state="$(curl -s -m 5 "http://${TARGET_HOST}:${PAYMENT_ADMIN_PORT}/admin/fault" || true)"
echo "== Falla de payment-service =="
echo "${fault_state:-no disponible (payment-service no responde)}"
echo

print_urls
