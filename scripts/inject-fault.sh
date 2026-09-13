#!/usr/bin/env bash
# [LOCAL] Activa la falla determinista de payment-service (latencia + tasa de
# error configurables) para la demo del laboratorio F13, orquestando por SSH.
#
# Uso:
#   bash scripts/inject-fault.sh [FAULT_LATENCY_MS] [FAULT_ERROR_RATE] [-y|--yes]
#   bash scripts/inject-fault.sh -h|--help
#
# Ejemplos:
#   bash scripts/inject-fault.sh                  # usa defaults 1800 ms / 0.30
#   bash scripts/inject-fault.sh 2500 0.5         # falla más agresiva
#   bash scripts/inject-fault.sh --yes            # sin confirmación interactiva

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

TARGET_SERVICE="payment-service"
ADMIN_PORT=8001
DEFAULT_LATENCY_MS=1800
DEFAULT_ERROR_RATE=0.30
ASSUME_YES="false"

usage() {
    cat <<'EOF'
Uso: bash scripts/inject-fault.sh [FAULT_LATENCY_MS] [FAULT_ERROR_RATE] [-y|--yes]

[LOCAL] Activa una falla reproducible en payment-service dentro de la VM
remota, vía su API administrativa local (POST /admin/fault en localhost:8001,
solo accesible desde dentro de la VM, nunca expuesta a Internet).

Argumentos posicionales (opcionales):
  FAULT_LATENCY_MS   latencia adicional en ms a inyectar (default: 1800)
  FAULT_ERROR_RATE   tasa de error 0.0-1.0 a inyectar (default: 0.30)

Opciones:
  -y, --yes    omite la confirmación interactiva (útil en runbooks/CI)
  -h, --help   muestra esta ayuda

El script imprime el estado ANTERIOR y NUEVO de la falla, y verifica que la
métrica f13_fault_active pase a 1 en /metrics de payment-service.
EOF
}

# --- parseo de argumentos ------------------------------------------------------
positional=()
for arg in "$@"; do
    case "${arg}" in
        -h|--help)
            usage
            exit 0
            ;;
        -y|--yes)
            ASSUME_YES="true"
            ;;
        -*)
            log_error "Opción no reconocida: ${arg}"
            usage
            exit 1
            ;;
        *)
            positional+=("${arg}")
            ;;
    esac
done

FAULT_LATENCY_MS="${positional[0]:-${DEFAULT_LATENCY_MS}}"
FAULT_ERROR_RATE="${positional[1]:-${DEFAULT_ERROR_RATE}}"

if ! [[ "${FAULT_LATENCY_MS}" =~ ^[0-9]+$ ]]; then
    log_error "FAULT_LATENCY_MS debe ser un entero (ms). Recibido: '${FAULT_LATENCY_MS}'"
    exit 1
fi
if ! [[ "${FAULT_ERROR_RATE}" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]]; then
    log_error "FAULT_ERROR_RATE debe estar entre 0.0 y 1.0. Recibido: '${FAULT_ERROR_RATE}'"
    exit 1
fi

require_cmd ssh curl

log_info "Cargando estado local..."
load_state_file

# --- confirmación --------------------------------------------------------------
echo
echo "Se activará una falla en '${TARGET_SERVICE}' (VM ${VM_NAME}):"
echo "  latencia adicional : ${FAULT_LATENCY_MS} ms"
echo "  tasa de error       : ${FAULT_ERROR_RATE}"
echo
if [[ "${ASSUME_YES}" != "true" ]]; then
    if [[ -t 0 ]]; then
        read -r -p "¿Confirmas? [y/N]: " confirm
        if ! [[ "${confirm}" =~ ^[yY]([eE][sS])?$ ]]; then
            log_info "Cancelado por el operador."
            exit 0
        fi
    else
        log_warn "stdin no es una terminal; se asume confirmación (usa --yes para silenciar este aviso)."
    fi
fi

# --- obtener token admin (solo en memoria de este proceso) ----------------------
log_info "Leyendo FAULT_ADMIN_TOKEN desde .env remoto (no se imprime)..."
FAULT_ADMIN_TOKEN="$(ssh_exec "grep '^FAULT_ADMIN_TOKEN=' '${REMOTE_REPO_DIR}/.env' | cut -d'=' -f2-")"
if [[ -z "${FAULT_ADMIN_TOKEN}" ]]; then
    log_error "No se pudo leer FAULT_ADMIN_TOKEN desde ${REMOTE_REPO_DIR}/.env en la VM."
    exit 1
fi

# admin_fault_request <METODO> [<json_body>]
# Envía la petición a /admin/fault dentro de la VM SIN exponer el token como
# argumento de línea de comandos remoto (visible en `ps aux` de otros
# usuarios de la VM): usamos `curl -K -` (config de curl leída por stdin) y
# canalizamos ese stdin a través del propio canal SSH cifrado. El token solo
# vive en la variable local FAULT_ADMIN_TOKEN de este script.
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

parse_body() {
    sed 's/HTTP_STATUS:[0-9]*$//'
}

parse_status() {
    grep -o 'HTTP_STATUS:[0-9]*$' | cut -d: -f2
}

# --- estado anterior -------------------------------------------------------------
log_info "Consultando estado ANTERIOR de la falla (GET /admin/fault)..."
before_raw="$(admin_fault_request GET)"
before_status="$(parse_status <<<"${before_raw}")"
before_body="$(parse_body <<<"${before_raw}")"
if [[ "${before_status}" != "200" ]]; then
    log_error "GET /admin/fault respondió HTTP ${before_status}. Respuesta: ${before_body}"
    exit 1
fi
echo "Estado ANTERIOR: ${before_body}"

# --- activar falla -----------------------------------------------------------------
log_info "Activando falla (POST /admin/fault)..."
fault_body="{\"active\":true,\"latency_ms\":${FAULT_LATENCY_MS},\"error_rate\":${FAULT_ERROR_RATE}}"
after_raw="$(admin_fault_request POST "${fault_body}")"
after_status="$(parse_status <<<"${after_raw}")"
after_body="$(parse_body <<<"${after_raw}")"
if [[ "${after_status}" != "200" ]]; then
    log_error "POST /admin/fault respondió HTTP ${after_status}. Respuesta: ${after_body}"
    exit 1
fi
echo "Estado NUEVO: ${after_body}"

# --- verificar métrica f13_fault_active=1 ------------------------------------------
log_info "Verificando f13_fault_active=1 en /metrics de payment-service..."
check_metric_is_one() {
    local metrics
    metrics="$(ssh_exec "curl -s http://localhost:${ADMIN_PORT}/metrics")"
    grep -qE '^f13_fault_active[[:space:]]+1(\.0+)?$' <<<"${metrics}"
}
if ! retry 6 5 check_metric_is_one; then
    log_error "f13_fault_active no llegó a 1 tras varios intentos. Revisa payment-service."
    exit 1
fi

log_info "Falla activa confirmada (f13_fault_active=1). Listo para la demo."

# Limpiar el token de memoria del proceso lo antes posible.
unset FAULT_ADMIN_TOKEN
