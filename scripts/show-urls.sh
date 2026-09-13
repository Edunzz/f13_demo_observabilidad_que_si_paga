#!/usr/bin/env bash
# [LOCAL] Imprime las URLs vigentes del laboratorio F13 (aplicación, Grafana,
# Jaeger) según la IP pública conocida.
#
# Por defecto usa el valor cacheado en .f13demo-state.env (rápido, sin
# depender de Azure CLI). Con --refresh, re-consulta la IP pública actual con
# `az network public-ip show` (patrón equivalente al de infra/azure/status.sh)
# por si la IP cambió fuera de banda.
#
# Uso:
#   bash scripts/show-urls.sh [--refresh] [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

REFRESH="false"

usage() {
    cat <<'EOF'
Uso: bash scripts/show-urls.sh [--refresh] [-h|--help]

[LOCAL] Imprime las URLs vigentes del laboratorio F13:
  - Aplicación / landing demo : http://<IP>:8080
  - Grafana                   : http://<IP>:3000
  - Jaeger                    : http://<IP>:16686

Sin --refresh, usa la IP cacheada en .f13demo-state.env (PUBLIC_IP).
Con --refresh, re-consulta la IP pública actual vía `az network public-ip
show` (requiere Azure CLI autenticado) y avisa si difiere de la cacheada.
EOF
}

for arg in "$@"; do
    case "${arg}" in
        -h|--help)
            usage
            exit 0
            ;;
        --refresh)
            REFRESH="true"
            ;;
        *)
            log_error "Argumento no reconocido: ${arg}"
            usage
            exit 1
            ;;
    esac
done

log_info "Cargando estado local..."
load_state_file

CURRENT_IP="${PUBLIC_IP}"

if [[ "${REFRESH}" == "true" ]]; then
    require_cmd az
    log_info "Re-consultando IP pública actual (az network public-ip show)..."
    fresh_ip="$(az network public-ip show \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${PUBLIC_IP_NAME}" \
        --query ipAddress -o tsv)"
    if [[ -z "${fresh_ip}" || "${fresh_ip}" == "null" ]]; then
        log_error "No se pudo obtener una IP pública asignada para ${PUBLIC_IP_NAME} (¿la VM está desalocada?)."
        exit 1
    fi
    if [[ "${fresh_ip}" != "${PUBLIC_IP}" ]]; then
        log_warn "La IP pública actual (${fresh_ip}) difiere de la cacheada en ${STATE_FILE} (${PUBLIC_IP})."
        log_warn "Actualiza manualmente PUBLIC_IP en ${STATE_FILE} si vas a seguir usando estos scripts."
    fi
    CURRENT_IP="${fresh_ip}"
fi

echo "== URLs del laboratorio F13 (${VM_NAME}) =="
echo "Aplicación / landing demo : http://${CURRENT_IP}:8080"
echo "Grafana                   : http://${CURRENT_IP}:3000"
echo "Jaeger                    : http://${CURRENT_IP}:16686"
