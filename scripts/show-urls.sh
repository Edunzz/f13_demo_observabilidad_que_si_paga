#!/usr/bin/env bash
# Imprime las URLs del laboratorio F13. Dentro de un GitHub Codespace usa las
# URLs de port forwarding (<codespace>-<puerto>.<dominio>); fuera de
# Codespaces, http://localhost:<puerto>.
#
# Uso:
#   bash scripts/show-urls.sh [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

usage() {
    cat <<'EOF'
Uso: bash scripts/show-urls.sh [-h|--help]

Imprime las URLs del laboratorio F13 (Grafana, dashboards, Jaeger,
Prometheus y la Swagger UI de shop-api) y cómo obtener las credenciales de
administrador de Grafana sin mostrarlas en pantalla.
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

print_urls
echo
echo "Grafana abre sin login (acceso anónimo con rol Editor: es solo una demo)."
echo "Si necesitas el usuario admin, su contraseña está en .env:"
echo "  grep GF_SECURITY_ADMIN_PASSWORD .env"
