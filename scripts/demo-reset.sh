#!/usr/bin/env bash
# [LOCAL] Deja el laboratorio F13 listo para repetir la demo: recupera la
# falla, reinicia el acumulador financiero y corre un smoke test rápido.
#
# Uso:
#   bash scripts/demo-reset.sh [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

VALUE_EXPORTER_PORT=9200

usage() {
    cat <<'EOF'
Uso: bash scripts/demo-reset.sh [-h|--help]

[LOCAL] Deja el entorno listo para repetir la demo, en este orden:
  1. Ejecuta scripts/recover.sh (desactiva la falla, sin reiniciar el stack)
  2. Reinicia el acumulador financiero: POST /admin/reset-accumulator en
     value-exporter (puerto 9200, solo alcanzable dentro de la VM vía SSH)
  3. Corre un smoke test rápido (TARGET_HOST=localhost) para confirmar
     estado saludable
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

# --- 1. Recuperar falla -----------------------------------------------------------
# NOTA DE DISEÑO: invocamos recover.sh como proceso separado (no `source`) para
# que su propio `set -Eeuo pipefail` y trap ERR apliquen de forma aislada; si
# recover.sh falla, este script debe abortar igual (gracias a `set -e`), sin
# arriesgar que variables/traps de recover.sh contaminen este script.
log_info "Paso 1/3: recuperando falla (scripts/recover.sh)..."
bash "${SCRIPT_DIR}/recover.sh"

# --- 2. Reiniciar acumulador financiero -----------------------------------------
log_info "Paso 2/3: reiniciando acumulador financiero (value-exporter, POST /admin/reset-accumulator)..."
reset_response="$(ssh_exec "curl -s -o /dev/null -w '%{http_code}' -X POST 'http://localhost:${VALUE_EXPORTER_PORT}/admin/reset-accumulator'")"
if [[ "${reset_response}" != "200" ]]; then
    log_error "POST /admin/reset-accumulator en value-exporter respondió HTTP ${reset_response} (se esperaba 200)."
    exit 1
fi
log_info "Acumulador financiero reiniciado."

# --- 3. Smoke test rápido ---------------------------------------------------------
log_info "Paso 3/3: ejecutando smoke test rápido dentro de la VM (TARGET_HOST=localhost)..."
ssh_exec "cd '${REMOTE_REPO_DIR}' && TARGET_HOST=localhost bash scripts/smoke-test.sh"

log_info "demo-reset.sh completo: el laboratorio está listo para repetir la demo."
