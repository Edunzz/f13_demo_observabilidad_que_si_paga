#!/usr/bin/env bash
# [LOCAL] Desactiva la falla inyectada en payment-service SIN reiniciar el
# stack completo, y confirma que f13_fault_active vuelva a 0.
#
# Uso:
#   bash scripts/recover.sh [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

ADMIN_PORT=8001

usage() {
    cat <<'EOF'
Uso: bash scripts/recover.sh [-h|--help]

[LOCAL] Desactiva la falla activa en payment-service (POST /admin/fault con
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

require_cmd ssh curl

log_info "Cargando estado local..."
load_state_file

log_info "Leyendo FAULT_ADMIN_TOKEN desde .env remoto (no se imprime)..."
FAULT_ADMIN_TOKEN="$(ssh_exec "grep '^FAULT_ADMIN_TOKEN=' '${REMOTE_REPO_DIR}/.env' | cut -d'=' -f2-")"
if [[ -z "${FAULT_ADMIN_TOKEN}" ]]; then
    log_error "No se pudo leer FAULT_ADMIN_TOKEN desde ${REMOTE_REPO_DIR}/.env en la VM."
    exit 1
fi

# Mismo enfoque que inject-fault.sh: config de curl por stdin (-K -) sobre el
# canal SSH, para no exponer el token como argumento de proceso en la VM.
admin_fault_request() {
    local method="$1"
    local data="${2:-}"
    local cfg
    cfg="url = \"http://localhost:${ADMIN_PORT}/admin/fault\"
request = \"${method}\"
header = \"X-Fault-Admin-Token: ${FAULT_ADMIN_TOKEN}\"
header = \"Content-Type: application/json\"
silent
show-error
write-out = \"HTTP_STATUS:%{http_code}\""
    if [[ -n "${data}" ]]; then
        local escaped="${data//\"/\\\"}"
        cfg="${cfg}
data = \"${escaped}\""
    fi
    printf '%s\n' "${cfg}" | ssh_exec "curl -K -"
}

parse_body() { sed 's/HTTP_STATUS:[0-9]*$//'; }
parse_status() { grep -o 'HTTP_STATUS:[0-9]*$' | cut -d: -f2; }

log_info "Consultando estado ANTERIOR de la falla (GET /admin/fault)..."
before_raw="$(admin_fault_request GET)"
before_status="$(parse_status <<<"${before_raw}")"
before_body="$(parse_body <<<"${before_raw}")"
if [[ "${before_status}" != "200" ]]; then
    log_error "GET /admin/fault respondió HTTP ${before_status}. Respuesta: ${before_body}"
    exit 1
fi
echo "Estado ANTERIOR: ${before_body}"

log_info "Desactivando falla (POST /admin/fault {active:false})..."
after_raw="$(admin_fault_request POST '{"active":false}')"
after_status="$(parse_status <<<"${after_raw}")"
after_body="$(parse_body <<<"${after_raw}")"
if [[ "${after_status}" != "200" ]]; then
    log_error "POST /admin/fault respondió HTTP ${after_status}. Respuesta: ${after_body}"
    exit 1
fi
echo "Estado NUEVO: ${after_body}"

log_info "Verificando f13_fault_active=0 en /metrics de payment-service..."
check_metric_is_zero() {
    local metrics
    metrics="$(ssh_exec "curl -s http://localhost:${ADMIN_PORT}/metrics")"
    grep -qE '^f13_fault_active[[:space:]]+0(\.0+)?$' <<<"${metrics}"
}
if ! retry 6 5 check_metric_is_zero; then
    log_error "f13_fault_active no volvió a 0 tras varios intentos. Revisa payment-service."
    exit 1
fi

log_info "Recuperación confirmada (f13_fault_active=0)."

unset FAULT_ADMIN_TOKEN
