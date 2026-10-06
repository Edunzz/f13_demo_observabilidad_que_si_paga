#!/usr/bin/env bash
# Biblioteca compartida por los scripts de operación del laboratorio F13.
#
# Este archivo NO se ejecuta directamente: se importa con
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# desde cada script en scripts/*.sh.
#
# Todos los scripts corren en la MISMA máquina donde vive el stack Docker
# Compose: el GitHub Codespace (o cualquier entorno con Docker que abra el
# devcontainer del repo). No hay SSH ni infraestructura remota.
#
# Provee: logging con timestamps/colores, validación de dependencias, lectura
# de .env sin imprimir secretos, espera de Docker y de healthchecks, URLs
# (con soporte de port forwarding de Codespaces), llamadas a la API admin de
# payment-service y un helper de reintentos.

# No usamos `set -Eeuo pipefail` aquí a propósito: este archivo solo declara
# funciones y variables; el script que hace `source` es quien define sus
# propias opciones de shell.

# ---------------------------------------------------------------------------
# Rutas, puertos y configuración compartida
# ---------------------------------------------------------------------------

# Directorio raíz del repo (scripts/ está un nivel por debajo de la raíz).
F13_REPO_ROOT="${F13_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Archivo .env con la configuración y los secretos generados por
# scripts/setup-env.sh. Nunca se commitea (ver .gitignore).
ENV_FILE="${ENV_FILE:-${F13_REPO_ROOT}/.env}"

# Host contra el que se prueban los servicios. Los puertos están publicados
# en el propio Codespace, así que por defecto es localhost.
TARGET_HOST="${TARGET_HOST:-localhost}"

# Puertos publicados por compose.yaml en el host del Codespace.
SHOP_API_PORT=8080
GRAFANA_PORT=3000
JAEGER_PORT=16686
PROMETHEUS_PORT=9090
PAYMENT_ADMIN_PORT=8001
# shellcheck disable=SC2034  # usado por demo-reset.sh y collect-diagnostics.sh
VALUE_EXPORTER_PORT=9200

# ---------------------------------------------------------------------------
# Logging con timestamps y colores (degrada sin color si la terminal no lo
# soporta o si la salida no es una terminal, p. ej. redirigida a un archivo).
# ---------------------------------------------------------------------------

_f13_supports_color() {
    # Solo pintamos si stderr es una terminal y tput reporta >=8 colores.
    if [[ ! -t 2 ]]; then
        return 1
    fi
    if ! command -v tput >/dev/null 2>&1; then
        return 1
    fi
    local ncolors
    ncolors="$(tput colors 2>/dev/null || echo 0)"
    [[ "${ncolors}" =~ ^[0-9]+$ ]] && [[ "${ncolors}" -ge 8 ]]
}

if _f13_supports_color; then
    _F13_COLOR_INFO="$(tput setaf 4)"
    _F13_COLOR_WARN="$(tput setaf 3)"
    _F13_COLOR_ERROR="$(tput setaf 1)"
    _F13_COLOR_RESET="$(tput sgr0)"
else
    _F13_COLOR_INFO=""
    _F13_COLOR_WARN=""
    _F13_COLOR_ERROR=""
    _F13_COLOR_RESET=""
fi

_f13_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Todos los logs van a stderr para no contaminar stdout (que puede contener
# salida "útil" de un script, ej. URLs a parsear por otra herramienta).
log_info() {
    printf '%s[%s] [INFO ] %s%s\n' "${_F13_COLOR_INFO}" "$(_f13_timestamp)" "$*" "${_F13_COLOR_RESET}" >&2
}

log_warn() {
    printf '%s[%s] [WARN ] %s%s\n' "${_F13_COLOR_WARN}" "$(_f13_timestamp)" "$*" "${_F13_COLOR_RESET}" >&2
}

log_error() {
    printf '%s[%s] [ERROR] %s%s\n' "${_F13_COLOR_ERROR}" "$(_f13_timestamp)" "$*" "${_F13_COLOR_RESET}" >&2
}

# Instala un trap de ERR que reporta línea y comando fallido usando log_error.
# IMPORTANTE: $BASH_COMMAND refleja el texto fuente del comando (sin expandir
# variables), por lo que nunca imprime valores de secretos referenciados por
# variable (p. ej. $token) — solo su nombre literal.
install_error_trap() {
    trap 'log_error "Fallo en ${BASH_SOURCE[0]:-script}, línea ${LINENO}: \"${BASH_COMMAND}\" (código $?)"' ERR
}

# ---------------------------------------------------------------------------
# Validación de dependencias
# ---------------------------------------------------------------------------

# require_cmd <nombre> [<nombre> ...]
# Verifica que cada comando exista en PATH; si falta alguno, error claro y exit 1.
require_cmd() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        log_error "Falta(n) comando(s) requerido(s) en PATH: ${missing[*]}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# .env (configuración + secretos generados por scripts/setup-env.sh)
# ---------------------------------------------------------------------------

# require_env_file
# Falla con un mensaje claro si .env no existe todavía.
require_env_file() {
    if [[ ! -f "${ENV_FILE}" ]]; then
        log_error "No existe '${ENV_FILE}'. Ejecuta primero: bash scripts/setup-env.sh (o bash scripts/lab-up.sh)"
        return 1
    fi
}

# env_value <CLAVE>
# Imprime el valor de <CLAVE> en .env (la última aparición gana, igual que
# docker compose). Pensado para capturarse en una variable, nunca para
# mostrarse en pantalla cuando la clave es un secreto.
env_value() {
    local key="$1"
    [[ -f "${ENV_FILE}" ]] || return 0
    grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 | cut -d'=' -f2- || true
}

# ---------------------------------------------------------------------------
# Docker / Docker Compose
# ---------------------------------------------------------------------------

# compose <args...>
# `docker compose` ejecutado siempre desde la raíz del repo, sin importar
# desde qué directorio se invoque el script.
compose() {
    (cd "${F13_REPO_ROOT}" && docker compose "$@")
}

# wait_for_docker [timeout_segundos]
# En un Codespace, el daemon de Docker (feature docker-in-docker) arranca en
# paralelo con los lifecycle commands del devcontainer; esperamos a que
# `docker info` responda antes de construir o levantar nada.
wait_for_docker() {
    local timeout="${1:-90}"
    local elapsed=0
    until docker info >/dev/null 2>&1; do
        if [[ "${elapsed}" -ge "${timeout}" ]]; then
            log_error "El daemon de Docker no respondió en ${timeout}s."
            return 1
        fi
        if [[ "${elapsed}" -eq 0 ]]; then
            log_info "Esperando a que el daemon de Docker esté disponible..."
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
}

# wait_for_healthy [timeout_segundos] [intervalo_segundos]
# Espera a que todos los contenedores del proyecto estén "healthy".
# "sin-healthcheck" es el estado ESPERADO y documentado en compose.yaml para
# load-generator (cliente en loop, sin endpoint HTTP propio) y otel-collector
# (imagen distroless sin shell/curl/wget); jaeger-init es un contenedor de
# una sola vez que termina con exit 0. Ninguno de esos casos bloquea.
wait_for_healthy() {
    local timeout="${1:-300}"
    local interval="${2:-5}"
    local elapsed=0
    local ids id name status state exit_code all_ready not_ready
    while true; do
        ids="$(compose ps -a -q 2>/dev/null || true)"
        if [[ -z "${ids}" ]]; then
            log_error "docker compose no reporta contenedores (¿falló 'docker compose up -d'?)."
            return 1
        fi
        all_ready=true
        not_ready=""
        for id in ${ids}; do
            name="$(docker inspect --format '{{.Name}}' "${id}" | sed 's#^/##')"
            state="$(docker inspect --format '{{.State.Status}}' "${id}")"
            status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}sin-healthcheck{{end}}' "${id}")"
            if [[ "${state}" == "exited" && "${name}" == *jaeger-init* ]]; then
                exit_code="$(docker inspect --format '{{.State.ExitCode}}' "${id}")"
                if [[ "${exit_code}" == "0" ]]; then
                    continue
                fi
            fi
            if [[ "${state}" != "running" ]]; then
                all_ready=false
                not_ready="${not_ready} ${name}:${state}"
            elif [[ "${status}" != "healthy" && "${status}" != "sin-healthcheck" ]]; then
                all_ready=false
                not_ready="${not_ready} ${name}:${status}"
            fi
        done
        if [[ "${all_ready}" == "true" ]]; then
            return 0
        fi
        if [[ "${elapsed}" -ge "${timeout}" ]]; then
            log_error "Timeout (${timeout}s) esperando healthchecks. No listos:${not_ready}"
            return 1
        fi
        log_info "Esperando healthchecks (${elapsed}s/${timeout}s):${not_ready}"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done
}

# ---------------------------------------------------------------------------
# URLs (localhost o port forwarding de GitHub Codespaces)
# ---------------------------------------------------------------------------

# in_codespace
# Verdadero si el script corre dentro de un GitHub Codespace.
in_codespace() {
    [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]
}

# public_url <puerto>
# URL para abrir <puerto> en el navegador. Los servicios hablan HTTP plano;
# en Codespaces la URL es la del port forwarding de GitHub
# (<codespace>-<puerto>.<dominio>), que GitHub sirve siempre con su propio
# https en el borde: no es configuración del laboratorio. Fuera de
# Codespaces es http://localhost:<puerto>.
public_url() {
    local port="$1"
    if in_codespace; then
        printf 'https://%s-%s.%s' "${CODESPACE_NAME}" "${port}" "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
    else
        printf 'http://localhost:%s' "${port}"
    fi
}

# print_urls
# Imprime la tabla de URLs del laboratorio en stdout.
print_urls() {
    echo "== URLs del laboratorio F13 =="
    printf '%-38s %s\n' "Grafana (dashboards)" "$(public_url "${GRAFANA_PORT}")"
    printf '%-38s %s\n' "  - F13 | Salud tecnica" "$(public_url "${GRAFANA_PORT}")/d/f13-tecnico"
    printf '%-38s %s\n' "  - F13 | Impacto en el negocio" "$(public_url "${GRAFANA_PORT}")/d/f13-impacto-negocio"
    printf '%-38s %s\n' "Jaeger (trazas)" "$(public_url "${JAEGER_PORT}")"
    printf '%-38s %s\n' "Prometheus (PromQL)" "$(public_url "${PROMETHEUS_PORT}")"
    printf '%-38s %s\n' "shop-api (Swagger en /docs)" "$(public_url "${SHOP_API_PORT}")/docs"
    if in_codespace; then
        echo
        echo "Tip: también las tienes en la pestaña 'PORTS' de VS Code. lab-up.sh las"
        echo "publica (visibilidad Public) para la demo; vuelve a privadas con:"
        echo "  bash scripts/publish-ports.sh --private"
    fi
}

# ---------------------------------------------------------------------------
# API admin de payment-service (activar/desactivar la falla)
# ---------------------------------------------------------------------------

# payment_admin_request <METODO> [<json_body>]
# Llama a /admin/fault de payment-service (localhost:8001, publicado solo en
# 127.0.0.1). El token admin se lee de .env y se entrega a curl por stdin
# (`curl -K -`), nunca como argumento de línea de comandos (visible en `ps`).
# Imprime el cuerpo de la respuesta seguido de "HTTP_STATUS:<código>".
payment_admin_request() {
    local method="$1"
    local data="${2:-}"
    local token cfg
    token="$(env_value FAULT_ADMIN_TOKEN)"
    if [[ -z "${token}" ]]; then
        log_error "FAULT_ADMIN_TOKEN no está definido en ${ENV_FILE}."
        return 1
    fi
    cfg="url = \"http://${TARGET_HOST}:${PAYMENT_ADMIN_PORT}/admin/fault\"
request = \"${method}\"
header = \"X-Fault-Admin-Token: ${token}\"
header = \"Content-Type: application/json\"
silent
show-error
max-time = 10
write-out = \"HTTP_STATUS:%{http_code}\""
    if [[ -n "${data}" ]]; then
        local escaped="${data//\"/\\\"}"
        cfg="${cfg}
data = \"${escaped}\""
    fi
    printf '%s\n' "${cfg}" | curl -K -
}

parse_body() {
    sed 's/HTTP_STATUS:[0-9]*$//'
}

parse_status() {
    grep -o 'HTTP_STATUS:[0-9]*$' | cut -d: -f2
}

# fault_metric_is <0|1>
# Verdadero si /metrics de payment-service reporta f13_fault_active = <valor>.
fault_metric_is() {
    local expected="$1"
    local metrics
    metrics="$(curl -s -m 5 "http://${TARGET_HOST}:${PAYMENT_ADMIN_PORT}/metrics" || true)"
    grep -qE "^f13_fault_active[[:space:]]+${expected}(\.0+)?$" <<<"${metrics}"
}

# ---------------------------------------------------------------------------
# Reintentos
# ---------------------------------------------------------------------------

# retry <intentos> <segundos_entre_intentos> <comando...>
# Reintenta <comando...> hasta <intentos> veces, esperando <segundos> entre
# cada intento. Devuelve el código de salida del último intento si todos fallan.
retry() {
    local attempts="$1"
    local sleep_seconds="$2"
    shift 2
    local n=1
    local rc=0
    while true; do
        if "$@"; then
            return 0
        fi
        rc=$?
        if [[ "${n}" -ge "${attempts}" ]]; then
            log_error "retry: '$*' falló tras ${n} intento(s) (código ${rc})"
            return "${rc}"
        fi
        log_warn "retry: intento ${n}/${attempts} de '$*' falló (código ${rc}); reintentando en ${sleep_seconds}s..."
        sleep "${sleep_seconds}"
        n=$((n + 1))
    done
}
