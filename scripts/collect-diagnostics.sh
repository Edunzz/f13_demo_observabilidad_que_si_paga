#!/usr/bin/env bash
# [LOCAL] Recolecta diagnóstico del laboratorio F13 desde la VM remota (vía
# SSH) y lo empaqueta en un .tar.gz local con timestamp, sanitizando
# secretos antes de escribir cualquier archivo en disco.
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

[LOCAL] Recolecta, vía SSH, en la VM remota f13demo:
  - docker compose ps
  - últimos 200 logs de cada contenedor (docker compose logs --tail=200)
  - docker compose config (SANITIZADO: se redactan valores de PASSWORD/
    TOKEN/SECRET antes de escribir el archivo en disco)
  - uso de disco (df -h) y memoria (free -h)
  - resultado de los health endpoints (shop-api, Grafana, Jaeger)

Empaqueta todo en:
  diagnostics/f13demo-diagnostics-<timestamp-UTC>.tar.gz

IMPORTANTE: el directorio 'diagnostics/' es local y NO debe commitearse.
Este script no modifica .gitignore; agrégalo manualmente si no está.
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

require_cmd ssh tar

log_info "Cargando estado local..."
load_state_file

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
# Es una defensa best-effort, no una garantía absoluta de que no queden
# secretos en el archivo; por eso además evitamos leer los valores reales de
# GF_SECURITY_ADMIN_PASSWORD/FAULT_ADMIN_TOKEN en ningún momento de este script.
sanitize_file() {
    local file="$1"
    sed -i -E 's/^([^=:]*(PASSWORD|TOKEN|SECRET|APIKEY|API_KEY)[^=:]*[=:]).*/\1 [REDACTADO]/I' "${file}"
}

log_info "Recolectando 'docker compose ps'..."
ssh_repo "docker compose ps" >"${BUNDLE_DIR}/docker-compose-ps.txt" 2>&1

log_info "Recolectando logs recientes (--tail=200) de todos los contenedores..."
ssh_repo "docker compose logs --no-color --tail=200" >"${BUNDLE_DIR}/docker-compose-logs.txt" 2>&1

log_info "Recolectando 'docker compose config' (se sanitiza antes de guardar)..."
ssh_repo "docker compose config" >"${BUNDLE_DIR}/docker-compose-config.raw.txt" 2>&1
sanitize_file "${BUNDLE_DIR}/docker-compose-config.raw.txt"
mv "${BUNDLE_DIR}/docker-compose-config.raw.txt" "${BUNDLE_DIR}/docker-compose-config.sanitized.txt"

log_info "Recolectando uso de disco y memoria..."
{
    echo "== df -h =="
    ssh_exec "df -h"
    echo
    echo "== free -h =="
    ssh_exec "free -h"
} >"${BUNDLE_DIR}/disk-memory.txt" 2>&1

log_info "Verificando health endpoints (no invasivo: no se ejecuta /checkout)..."
{
    echo "== shop-api /health (localhost:8080) =="
    ssh_exec "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:8080/health" || true
    echo "== shop-api /ready (localhost:8080) =="
    ssh_exec "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:8080/ready" || true
    echo "== Grafana /api/health (localhost:3000) =="
    ssh_exec "curl -s http://localhost:3000/api/health" || true
    echo
    echo "== Jaeger UI (localhost:16686) =="
    ssh_exec "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:16686/" || true
    echo "== Prometheus (localhost:9090) =="
    ssh_exec "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:9090/-/healthy" || true
} >"${BUNDLE_DIR}/health-endpoints.txt" 2>&1
# NOTA: los `|| true` de este bloque son deliberados y documentados: un
# endpoint caído es precisamente lo que este diagnóstico busca detectar y
# reportar en el archivo, no debe abortar la recolección del resto.

log_info "Escaneando el bundle en busca de patrones de secretos remanentes (best-effort)..."
if grep -riE '(password|token|secret|apikey)[[:space:]]*[:=][[:space:]]*[^[:space:]\[]' "${BUNDLE_DIR}" 2>/dev/null | grep -v '\[REDACTADO\]'; then
    log_warn "Se detectaron posibles secretos no redactados (ver arriba). Revisa manualmente antes de compartir el paquete."
fi

mkdir -p "${DIAG_DIR}"
TARBALL="${DIAG_DIR}/${BUNDLE_NAME}.tar.gz"
tar -C "${WORKDIR}" -czf "${TARBALL}" "${BUNDLE_NAME}"

log_info "Diagnóstico empaquetado en: ${TARBALL}"
log_warn "Recuerda agregar 'diagnostics/' a .gitignore si aún no está (este script no lo edita)."
