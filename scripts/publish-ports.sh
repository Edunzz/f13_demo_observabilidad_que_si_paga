#!/usr/bin/env bash
# Publica (o vuelve a hacer privados) los puertos web del laboratorio F13 en
# el GitHub Codespace: Grafana, Jaeger, Prometheus y shop-api.
#
# Los servicios hablan HTTP plano (sin TLS ni certificados). Lo único que
# cambia aquí es la VISIBILIDAD del port forwarding de Codespaces:
#   - public : cualquiera con la URL abre la web, sin iniciar sesión en GitHub
#   - private: solo tu cuenta de GitHub (valor por defecto de Codespaces)
#
# La API admin de payment-service (8001) y value-exporter (9200) NUNCA se
# publican: la falla solo se inyecta desde la terminal del Codespace.
#
# Uso:
#   bash scripts/publish-ports.sh [--private] [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

VISIBILITY="public"
WEB_PORTS=("${GRAFANA_PORT}" "${JAEGER_PORT}" "${PROMETHEUS_PORT}" "${SHOP_API_PORT}")
ATTEMPTS=6
RETRY_SECONDS=10

usage() {
    cat <<'EOF'
Uso: bash scripts/publish-ports.sh [--private] [-h|--help]

Cambia la visibilidad de los puertos web del laboratorio en el Codespace
(3000 Grafana, 16686 Jaeger, 9090 Prometheus, 8080 shop-api):
  (sin opciones)  public  -> se abren sin login de GitHub (modo demo)
  --private       private -> solo tu cuenta de GitHub

Usa `gh codespace ports visibility`. scripts/lab-up.sh lo ejecuta
automáticamente al final. Si tu organización bloquea los puertos públicos,
el script avisa y los puertos quedan privados.
EOF
}

for arg in "$@"; do
    case "${arg}" in
        -h|--help)
            usage
            exit 0
            ;;
        --private)
            VISIBILITY="private"
            ;;
        *)
            log_error "Argumento no reconocido: ${arg}"
            usage
            exit 1
            ;;
    esac
done

if ! in_codespace; then
    log_info "No estás en un GitHub Codespace: no hay port forwarding que publicar (usa http://localhost:<puerto>)."
    exit 0
fi

require_cmd gh

port_args=()
for port in "${WEB_PORTS[@]}"; do
    port_args+=("${port}:${VISIBILITY}")
done

log_info "Configurando puertos ${WEB_PORTS[*]} como '${VISIBILITY}' en el Codespace ${CODESPACE_NAME}..."
# Reintenta: Codespaces solo acepta cambiar la visibilidad de un puerto que ya
# está reenviado, y justo después de arrancar el stack puede tardar unos segundos.
if ! retry "${ATTEMPTS}" "${RETRY_SECONDS}" gh codespace ports visibility "${port_args[@]}" -c "${CODESPACE_NAME}"; then
    log_warn "No se pudo cambiar la visibilidad (¿política de tu organización?)."
    log_warn "Hazlo a mano: pestaña PORTS -> clic derecho en el puerto -> Port Visibility -> ${VISIBILITY^}."
    exit 1
fi

log_info "Puertos web en modo '${VISIBILITY}'."
