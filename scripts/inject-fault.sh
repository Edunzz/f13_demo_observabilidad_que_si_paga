#!/usr/bin/env bash
# Activa la falla determinista de payment-service (latencia + tasa de error
# configurables) para la demo del laboratorio F13.
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
DEFAULT_LATENCY_MS=1800
DEFAULT_ERROR_RATE=0.30
ASSUME_YES="false"

usage() {
    cat <<'EOF'
Uso: bash scripts/inject-fault.sh [FAULT_LATENCY_MS] [FAULT_ERROR_RATE] [-y|--yes]

Activa una falla reproducible en payment-service vía su API administrativa
(POST /admin/fault en localhost:8001, publicada solo en 127.0.0.1 del
Codespace). El token admin se lee de .env y nunca se imprime.

Argumentos posicionales (opcionales):
  FAULT_LATENCY_MS   latencia adicional en ms a inyectar (default: 1800)
  FAULT_ERROR_RATE   tasa de error 0.0-1.0 a inyectar (default: 0.30)

Opciones:
  -y, --yes    omite la confirmación interactiva
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

require_cmd curl
require_env_file

# --- confirmación --------------------------------------------------------------
echo
echo "Se activará una falla en '${TARGET_SERVICE}':"
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

# --- estado anterior -------------------------------------------------------------
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

# --- activar falla -----------------------------------------------------------------
log_info "Activando falla (POST /admin/fault)..."
fault_body="{\"active\":true,\"latency_ms\":${FAULT_LATENCY_MS},\"error_rate\":${FAULT_ERROR_RATE}}"
after_raw="$(payment_admin_request POST "${fault_body}")"
after_status="$(parse_status <<<"${after_raw}")"
after_body="$(parse_body <<<"${after_raw}")"
if [[ "${after_status}" != "200" ]]; then
    log_error "POST /admin/fault respondió HTTP ${after_status}. Respuesta: ${after_body}"
    exit 1
fi
echo "Estado NUEVO: ${after_body}"

# --- verificar métrica f13_fault_active=1 ------------------------------------------
log_info "Verificando f13_fault_active=1 en /metrics de payment-service..."
if ! retry 6 5 fault_metric_is 1; then
    log_error "f13_fault_active no llegó a 1 tras varios intentos. Revisa: docker compose logs payment-service"
    exit 1
fi

log_info "Falla activa confirmada (f13_fault_active=1)."
log_info "Observa el impacto: bash scripts/business-snapshot.sh  (o los dashboards de Grafana)."
