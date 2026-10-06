#!/usr/bin/env bash
# Recolecta diagnóstico del laboratorio F13 y lo empaqueta en un .tar.gz con
# timestamp, sanitizando secretos antes de escribir cualquier archivo en disco.
#
# Uso:
#   bash scripts/collect-diagnostics.sh [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

DIAG_DIR="${F13_REPO_ROOT}/diagnostics"

usage() {
    cat <<'EOF'
Uso: bash scripts/collect-diagnostics.sh [-h|--help]

Recolecta, en este Codespace:
  - docker compose ps
  - últimos 200 logs de cada contenedor (docker compose logs --tail=200)
  - docker compose config (SANITIZADO: se redactan valores de PASSWORD/
    TOKEN/SECRET antes de escribir el archivo en disco)
  - uso de disco (df -h) y memoria (free -h)
  - resultado de los health endpoints (shop-api, Grafana, Jaeger,
    Prometheus, payment-service, value-exporter)

Empaqueta todo en:
  diagnostics/f13demo-diagnostics-<timestamp-UTC>.tar.gz

El directorio 'diagnostics/' está en .gitignore: nunca se commitea.
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

require_cmd docker curl tar

TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
WORKDIR="$(mktemp -d)"
BUNDLE_NAME="f13demo-diagnostics-${TIMESTAMP}"
BUNDLE_DIR="${WORKDIR}/${BUNDLE_NAME}"
mkdir -p "${BUNDLE_DIR}"

cleanup() {
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# sanitize_file <archivo>
# Redacta (best-effort) cualquier línea que parezca contener una credencial:
# claves que contengan password/token/secret/apikey seguidas de '=' o ':'.
# Es una defensa best-effort; por eso además este script nunca lee .env.
sanitize_file() {
    local file="$1"
    sed -i -E 's/^([^=:]*(PASSWORD|TOKEN|SECRET|APIKEY|API_KEY)[^=:]*[=:]).*/\1 [REDACTADO]/I' "${file}"
}

log_info "Recolectando 'docker compose ps'..."
compose ps -a >"${BUNDLE_DIR}/docker-compose-ps.txt" 2>&1 || true

log_info "Recolectando logs recientes (--tail=200) de todos los contenedores..."
compose logs --no-color --tail=200 >"${BUNDLE_DIR}/docker-compose-logs.txt" 2>&1 || true

log_info "Recolectando 'docker compose config' (se sanitiza antes de guardar)..."
compose config >"${BUNDLE_DIR}/docker-compose-config.raw.txt" 2>&1 || true
sanitize_file "${BUNDLE_DIR}/docker-compose-config.raw.txt"
mv "${BUNDLE_DIR}/docker-compose-config.raw.txt" "${BUNDLE_DIR}/docker-compose-config.sanitized.txt"

log_info "Recolectando uso de disco y memoria..."
{
    echo "== df -h =="
    df -h
    echo
    echo "== free -h =="
    free -h
} >"${BUNDLE_DIR}/disk-memory.txt" 2>&1 || true

log_info "Verificando health endpoints (no invasivo: no se ejecuta /checkout)..."
# Los `|| true` de este bloque son deliberados: un endpoint caído es
# precisamente lo que este diagnóstico busca registrar, no debe abortarlo.
{
    echo "== shop-api /health (${SHOP_API_PORT}) =="
    curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' "http://${TARGET_HOST}:${SHOP_API_PORT}/health" || true
    echo "== shop-api /ready (${SHOP_API_PORT}) =="
    curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' "http://${TARGET_HOST}:${SHOP_API_PORT}/ready" || true
    echo "== Grafana /api/health (${GRAFANA_PORT}) =="
    curl -s -m 5 "http://${TARGET_HOST}:${GRAFANA_PORT}/api/health" || true
    echo
    echo "== Jaeger UI (${JAEGER_PORT}) =="
    curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' "http://${TARGET_HOST}:${JAEGER_PORT}/" || true
    echo "== Prometheus /-/healthy (${PROMETHEUS_PORT}) =="
    curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' "http://${TARGET_HOST}:${PROMETHEUS_PORT}/-/healthy" || true
    echo "== payment-service /admin/fault (${PAYMENT_ADMIN_PORT}) =="
    curl -s -m 5 "http://${TARGET_HOST}:${PAYMENT_ADMIN_PORT}/admin/fault" || true
    echo
    echo "== value-exporter /health (${VALUE_EXPORTER_PORT}) =="
    curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' "http://${TARGET_HOST}:${VALUE_EXPORTER_PORT}/health" || true
} >"${BUNDLE_DIR}/health-endpoints.txt" 2>&1

log_info "Escaneando el bundle en busca de patrones de secretos remanentes (best-effort)..."
if grep -riE '(password|token|secret|apikey)[[:space:]]*[:=][[:space:]]*[^[:space:]\[]' "${BUNDLE_DIR}" 2>/dev/null | grep -v '\[REDACTADO\]'; then
    log_warn "Se detectaron posibles secretos no redactados (ver arriba). Revisa manualmente antes de compartir el paquete."
fi

mkdir -p "${DIAG_DIR}"
TARBALL="${DIAG_DIR}/${BUNDLE_NAME}.tar.gz"
tar -C "${WORKDIR}" -czf "${TARBALL}" "${BUNDLE_NAME}"

log_info "Diagnóstico empaquetado en: ${TARBALL}"
