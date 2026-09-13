#!/usr/bin/env bash
# [LOCAL] Verifica que el stack del laboratorio F13 ya esté arriba y saludable
# en la VM remota, e imprime las URLs y un resumen del estado esperado.
#
# Este script es de solo lectura: NO reinicia contenedores ni instala nada.
# Si el stack no está corriendo, sugiere ejecutar remote-install.sh (pero no
# lo invoca automáticamente).
#
# Uso:
#   bash scripts/demo-start.sh [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

usage() {
    cat <<'EOF'
Uso: bash scripts/demo-start.sh [-h|--help]

[LOCAL] Verifica (sin modificar nada) que el stack Docker Compose del
laboratorio F13 esté arriba en la VM remota:
  - Conectividad SSH
  - `docker compose ps` (todos los servicios "running"/"healthy")
  - Imprime URLs de acceso y un resumen del estado inicial esperado

Si el stack no está corriendo, este script NO lo levanta: sugiere ejecutar
`bash scripts/remote-install.sh` primero.
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

require_cmd ssh

log_info "Cargando estado local..."
load_state_file

log_info "Verificando conectividad SSH a ${ADMIN_USER}@${PUBLIC_IP}..."
if ! ssh_exec "echo ok" >/dev/null; then
    log_error "No se pudo conectar por SSH a la VM. Revisa que esté encendida y el NSG/IP."
    exit 1
fi

log_info "Consultando estado de docker compose en la VM..."
if ! ps_output="$(ssh_repo "docker compose ps" 2>&1)"; then
    log_error "No se pudo ejecutar 'docker compose ps' en la VM (¿el repo no está clonado o el compose falló?)."
    log_error "Salida: ${ps_output}"
    log_error "Sugerencia: ejecuta primero: bash scripts/remote-install.sh"
    exit 1
fi

echo
echo "== Estado actual de los contenedores (${VM_NAME}) =="
echo "${ps_output}"
echo

# Si no hay ninguna línea con "Up"/"running", asumimos que el stack no arrancó.
if ! grep -qiE '\bUp\b|running|healthy' <<<"${ps_output}"; then
    log_warn "No se detectaron contenedores en ejecución."
    log_warn "Sugerencia: ejecuta primero: bash scripts/remote-install.sh"
    exit 1
fi

if grep -qi 'unhealthy\|restarting\|exited' <<<"${ps_output}"; then
    log_warn "Al menos un contenedor no está en estado saludable. Revisa con:"
    log_warn "  bash scripts/collect-diagnostics.sh"
fi

echo "== URLs del laboratorio =="
echo "Aplicación / landing demo : http://${PUBLIC_IP}:8080"
echo "Grafana                   : http://${PUBLIC_IP}:3000"
echo "Jaeger                    : http://${PUBLIC_IP}:16686"
echo
echo "== Estado inicial esperado =="
echo "- load-generator enviando tráfico continuo a /checkout"
echo "- f13_fault_active = 0 (sin falla activa)"
echo "- Tasa de error cercana a 0 y latencia p95 dentro de rangos normales"
echo "- Dashboard 'F13 | Impacto en el negocio' con ingreso en riesgo ~ 0 USD/min"
echo
log_info "demo-start.sh: verificación completa. El stack parece estar en ejecución."
