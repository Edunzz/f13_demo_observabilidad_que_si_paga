#!/usr/bin/env bash
# Desactiva la falla inyectada en payment-service SIN reiniciar el stack
# completo, y confirma que f13_fault_active vuelva a 0.
#
# Uso:
#   bash scripts/recover.sh [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

usage() {
    cat <<'EOF'
Uso: bash scripts/recover.sh [-h|--help]

Desactiva la falla activa en payment-service (POST /admin/fault con
{"active": false}) SIN reiniciar contenedores ni el stack completo, y
verifica que f13_fault_active vuelva a 0 en /metrics.
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

require_cmd curl
require_env_file

log_info "Consultando estado ANTERIOR de la falla (GET /admin/fault)..."
before_raw="$(payment_admin_request GET)"
before_status="$(parse_status <<<"${before_raw}")"
before_body="$(parse_body <<<"${before_raw}")"
if [[ "${before_status}" != "200" ]]; then
    log_error "GET /admin/fault respondió HTTP ${before_status}. Respuesta: ${before_body}"
    log_error "¿Está arriba el stack? Revisa con: bash scripts/status.sh"
    exit 1
fi
echo "Estado ANTERIOR: ${before_body}"

log_info "Desactivando falla (POST /admin/fault {active:false})..."
after_raw="$(payment_admin_request POST '{"active":false}')"
after_status="$(parse_status <<<"${after_raw}")"
after_body="$(parse_body <<<"${after_raw}")"
if [[ "${after_status}" != "200" ]]; then
    log_error "POST /admin/fault respondió HTTP ${after_status}. Respuesta: ${after_body}"
    exit 1
fi
echo "Estado NUEVO: ${after_body}"

log_info "Verificando f13_fault_active=0 en /metrics de payment-service..."
if ! retry 6 5 fault_metric_is 0; then
    log_error "f13_fault_active no volvió a 0 tras varios intentos. Revisa: docker compose logs payment-service"
    exit 1
fi

log_info "Recuperación confirmada (f13_fault_active=0)."
