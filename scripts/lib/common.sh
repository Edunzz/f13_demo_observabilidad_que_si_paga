#!/usr/bin/env bash
# [LOCAL] Biblioteca compartida por los scripts de operación del laboratorio F13.
#
# Este archivo NO se ejecuta directamente: se importa con
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# desde cada script en scripts/*.sh que corre en la máquina del operador.
#
# Provee: logging con timestamps/colores, validación de dependencias, carga
# del estado generado por infra/azure/deploy.sh, ejecución remota vía SSH y
# un helper de reintentos.

# No usamos `set -Eeuo pipefail` aquí a propósito: este archivo solo declara
# funciones y variables; el script que hace `source` es quien define sus
# propias opciones de shell (según las reglas transversales del proyecto).

# ---------------------------------------------------------------------------
# Rutas y configuración compartida
# ---------------------------------------------------------------------------

# Directorio raíz del repo (scripts/ está un nivel por debajo de la raíz).
F13_REPO_ROOT="${F13_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Archivo de estado generado por infra/azure/deploy.sh. Nunca se commitea
# (ver .gitignore) y nunca contiene secretos.
STATE_FILE="${STATE_FILE:-${F13_REPO_ROOT}/.f13demo-state.env}"

# Ruta del repo ya clonado dentro de la VM remota (ver remote-install.sh).
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-/opt/f13demo/repo}"

# Variables obligatorias que debe contener .f13demo-state.env.
_F13_REQUIRED_STATE_VARS=(RESOURCE_GROUP VM_NAME PUBLIC_IP ADMIN_USER VNET_NAME SUBNET_NAME NSG_NAME PUBLIC_IP_NAME NIC_NAME ADMIN_CIDR)

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
# variable (p. ej. $FAULT_ADMIN_TOKEN) — solo su nombre literal.
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
# Estado local (.f13demo-state.env)
# ---------------------------------------------------------------------------

# load_state_file [ruta]
# Carga el archivo de estado (por defecto $STATE_FILE) y valida que estén
# presentes las variables obligatorias del contrato compartido.
load_state_file() {
    local file="${1:-${STATE_FILE}}"
    if [[ ! -f "${file}" ]]; then
        log_error "No existe el archivo de estado '${file}'."
        log_error "Ejecuta primero: bash infra/azure/deploy.sh"
        return 1
    fi
    # shellcheck source=/dev/null
    source "${file}"
    local var missing=()
    for var in "${_F13_REQUIRED_STATE_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("${var}")
        fi
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        log_error "El archivo de estado '${file}' no define: ${missing[*]}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------

# ssh_exec <comando remoto...>
# Ejecuta un comando en la VM remota vía SSH usando ADMIN_USER/PUBLIC_IP del
# estado cargado. Los argumentos se concatenan (con espacio) por ssh antes de
# enviarse a la shell remota, por lo que basta pasar UNA cadena con el comando
# completo, p. ej.: ssh_exec "cd /opt/f13demo/repo && docker compose ps".
ssh_exec() {
    if [[ -z "${ADMIN_USER:-}" || -z "${PUBLIC_IP:-}" ]]; then
        log_error "ssh_exec: ADMIN_USER/PUBLIC_IP no están definidos (¿olvidaste load_state_file?)"
        return 1
    fi
    # SSH_PRIVATE_KEY_PATH lo escribe infra/azure/deploy.sh en el estado
    # (derivado de SSH_PUBLIC_KEY_PATH). Sin `-i` explícito, ssh solo intenta
    # las rutas por defecto (id_rsa/id_ecdsa/id_ed25519) o un ssh-agent
    # cargado, y falla en silencio si la clave del laboratorio tiene otro
    # nombre. Se pasa `-i` solo si la variable está definida y el archivo
    # existe, para no romper estados generados antes de este cambio (en ese
    # caso se mantiene el comportamiento anterior, basado en ssh-agent/rutas
    # por defecto).
    local -a _ssh_identity_opts=()
    if [[ -n "${SSH_PRIVATE_KEY_PATH:-}" && -f "${SSH_PRIVATE_KEY_PATH}" ]]; then
        _ssh_identity_opts=(-i "${SSH_PRIVATE_KEY_PATH}")
    fi
    ssh "${_ssh_identity_opts[@]}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${ADMIN_USER}@${PUBLIC_IP}" "$@"
}

# ssh_repo <comando remoto...>
# Igual que ssh_exec pero anteponiendo `cd "$REMOTE_REPO_DIR" &&` para que el
# comando se ejecute dentro del repo clonado en la VM.
ssh_repo() {
    ssh_exec "cd '${REMOTE_REPO_DIR}' && $*"
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
