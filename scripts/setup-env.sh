#!/usr/bin/env bash
# Crea (o completa) el archivo .env del laboratorio F13 a partir de
# .env.example y genera los secretos localmente, dentro del Codespace.
#
# Idempotente: nunca sobrescribe valores ya existentes (salvo
# GF_SERVER_ROOT_URL, que se recalcula para el Codespace actual) y nunca
# imprime secretos. Se ejecuta automáticamente como postCreateCommand del
# devcontainer y al inicio de scripts/lab-up.sh.
#
# Uso:
#   bash scripts/setup-env.sh [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

EXAMPLE_FILE="${F13_REPO_ROOT}/.env.example"
SECRET_KEYS=(GF_SECURITY_ADMIN_PASSWORD FAULT_ADMIN_TOKEN)

usage() {
    cat <<'EOF'
Uso: bash scripts/setup-env.sh [-h|--help]

Prepara el archivo .env del laboratorio F13:
  1. Si .env no existe, lo copia desde .env.example.
     Si ya existe, lo conserva y solo agrega las claves nuevas de .env.example.
  2. Reemplaza los placeholders CHANGE_ME de GF_SECURITY_ADMIN_PASSWORD y
     FAULT_ADMIN_TOKEN por secretos aleatorios (openssl rand -hex 24).
     Los secretos nunca se imprimen.
  3. Dentro de un GitHub Codespace, ajusta GF_SERVER_ROOT_URL a la URL de
     port forwarding de Grafana (<codespace>-3000.<dominio>).
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

gen_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
    else
        head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# set_env_value <CLAVE> <VALOR>
# Reemplaza la línea CLAVE=... de .env (o la agrega si no existe). El valor no
# debe contener '|' (delimitador de sed); los valores que escribe este script
# son hex o URLs, así que nunca lo contienen.
set_env_value() {
    local key="$1"
    local value="$2"
    if grep -qE "^${key}=" "${ENV_FILE}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
    else
        printf '%s=%s\n' "${key}" "${value}" >>"${ENV_FILE}"
    fi
}

if [[ ! -f "${EXAMPLE_FILE}" ]]; then
    log_error "No se encontró ${EXAMPLE_FILE}; no se puede crear .env."
    exit 1
fi

# 1. Crear o completar .env ----------------------------------------------------
if [[ -f "${ENV_FILE}" ]]; then
    # Garantiza salto de línea final antes de agregar claves.
    if [[ -s "${ENV_FILE}" && -n "$(tail -c 1 "${ENV_FILE}")" ]]; then
        printf '\n' >>"${ENV_FILE}"
    fi
    added=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        key="${BASH_REMATCH[1]}"
        if ! grep -qE "^${key}=" "${ENV_FILE}"; then
            printf '%s\n' "${line}" >>"${ENV_FILE}"
            added=$((added + 1))
        fi
    done <"${EXAMPLE_FILE}"
    log_info ".env ya existía: se conserva (${added} clave(s) nueva(s) agregada(s) desde .env.example)."
else
    cp "${EXAMPLE_FILE}" "${ENV_FILE}"
    log_info ".env creado a partir de .env.example."
fi

# 2. Secretos ----------------------------------------------------------------------
for key in "${SECRET_KEYS[@]}"; do
    current="$(env_value "${key}")"
    if [[ -z "${current}" || "${current}" == "CHANGE_ME" ]]; then
        set_env_value "${key}" "$(gen_secret)"
        log_info "Secreto ${key} generado en .env (no se imprime)."
    fi
done
unset current

# 3. URL pública de Grafana en Codespaces --------------------------------------------
if in_codespace; then
    root_url="$(public_url "${GRAFANA_PORT}")/"
    set_env_value GF_SERVER_ROOT_URL "${root_url}"
    log_info "GF_SERVER_ROOT_URL ajustada al Codespace: ${root_url}"
fi

chmod 600 "${ENV_FILE}"
log_info "setup-env.sh completo: ${ENV_FILE} listo."
