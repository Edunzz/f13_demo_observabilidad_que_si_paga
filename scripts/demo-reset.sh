#!/usr/bin/env bash
# Deja el laboratorio F13 listo para repetir la demo: recupera la falla,
# reinicia el acumulador financiero y corre el smoke test.
#
# Uso:
#   bash scripts/demo-reset.sh [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

usage() {
    cat <<'EOF'
Uso: bash scripts/demo-reset.sh [-h|--help]

Deja el entorno listo para repetir la demo, en este orden:
  1. Ejecuta scripts/recover.sh (desactiva la falla, sin reiniciar el stack)
  2. Reinicia el acumulador financiero: POST /admin/reset-accumulator en
     value-exporter (localhost:9200, publicado solo en 127.0.0.1)
  3. Corre scripts/smoke-test.sh para confirmar estado saludable
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

# --- 1. Recuperar falla -----------------------------------------------------------
# recover.sh se invoca como proceso separado (no `source`) para que su propio
# `set -Eeuo pipefail` y trap ERR apliquen de forma aislada.
log_info "Paso 1/3: recuperando falla (scripts/recover.sh)..."
bash "${SCRIPT_DIR}/recover.sh"

# --- 2. Reiniciar acumulador financiero -----------------------------------------
log_info "Paso 2/3: reiniciando acumulador financiero (value-exporter, POST /admin/reset-accumulator)..."
reset_code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST \
    "http://${TARGET_HOST}:${VALUE_EXPORTER_PORT}/admin/reset-accumulator" || echo "000")"
if [[ "${reset_code}" != "200" ]]; then
    log_error "POST /admin/reset-accumulator en value-exporter respondió HTTP ${reset_code} (se esperaba 200)."
    exit 1
fi
log_info "Acumulador financiero reiniciado."

# --- 3. Smoke test ------------------------------------------------------------------
log_info "Paso 3/3: ejecutando smoke test..."
bash "${SCRIPT_DIR}/smoke-test.sh"

log_info "demo-reset.sh completo: el laboratorio está listo para repetir la demo."
