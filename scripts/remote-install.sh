#!/usr/bin/env bash
# [LOCAL] Instala y arranca el stack del laboratorio F13 dentro de la VM
# remota `f13demo`, orquestando todo por SSH desde la máquina del operador.
#
# Requiere que `infra/azure/deploy.sh` ya haya corrido y haya generado
# `.f13demo-state.env` en la raíz del repo.
#
# Uso:
#   bash scripts/remote-install.sh [-h|--help]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

REPO_URL="https://github.com/Edunzz/f13_demo_observabilidad_que_si_paga.git"
HEALTH_TIMEOUT_SECONDS=300
HEALTH_POLL_INTERVAL_SECONDS=5

usage() {
    cat <<'EOF'
Uso: bash scripts/remote-install.sh [-h|--help]

[LOCAL] Instala/actualiza el stack Docker Compose del laboratorio F13 dentro
de la VM remota `f13demo`, en este orden:

  1. Carga .f13demo-state.env
  2. Verifica conectividad SSH
  3. Espera a que cloud-init termine
  4. Clona el repo (o hace fetch + fast-forward si ya existe y está limpio)
  5. Crea .env desde .env.example y genera secretos si no existe
  6. Valida `docker version` / `docker compose version`
  7. `docker compose config --quiet`
  8. `docker compose build --pull`
  9. `docker compose up -d`
  10. Espera todos los healthchecks (timeout total 5 minutos)
  11. Corre smoke tests locales dentro de la VM (TARGET_HOST=localhost)
  12. Imprime las URLs del laboratorio (sin secretos)

No requiere argumentos. Variables de entorno relevantes:
  STATE_FILE          ruta al archivo de estado (default: raíz del repo)
  REMOTE_REPO_DIR      ruta del repo dentro de la VM (default: /opt/f13demo/repo)
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

require_cmd ssh git

# 1. Cargar estado ------------------------------------------------------------
log_info "Paso 1/12: cargando estado local (${STATE_FILE})..."
load_state_file

# 2. Verificar SSH -------------------------------------------------------------
log_info "Paso 2/12: verificando conectividad SSH a ${ADMIN_USER}@${PUBLIC_IP}..."
if ! retry 5 5 ssh_exec "echo ok" >/dev/null; then
    log_error "No se pudo establecer SSH con la VM. Verifica NSG, IP pública y clave privada cargada en el agente SSH."
    exit 1
fi

# 3. Esperar cloud-init --------------------------------------------------------
log_info "Paso 3/12: esperando a que cloud-init termine en la VM (puede tardar varios minutos)..."
if ! ssh_exec "sudo cloud-init status --wait"; then
    log_error "cloud-init reportó un error o no terminó correctamente. Revisa /var/log/f13demo-cloud-init.log en la VM."
    exit 1
fi

# 4. Clonar o actualizar el repo ------------------------------------------------
log_info "Paso 4/12: verificando repo remoto en ${REMOTE_REPO_DIR}..."
if ssh_exec "test -d '${REMOTE_REPO_DIR}/.git'"; then
    log_info "El repo ya existe; verificando estado limpio antes de actualizar..."
    if ! ssh_exec "cd '${REMOTE_REPO_DIR}' && [ -z \"\$(git status --porcelain)\" ]"; then
        log_error "El repo remoto en ${REMOTE_REPO_DIR} tiene cambios locales sin commitear."
        log_error "Aborta y resuélvelos manualmente por SSH; no se forzará ningún git reset/checkout/merge."
        exit 1
    fi
    log_info "Repo limpio. Ejecutando git fetch + fast-forward..."
    ssh_repo "git fetch origin && git pull --ff-only"
else
    log_info "El repo no existe todavía; clonando ${REPO_URL}..."
    ssh_exec "test -d '${REMOTE_REPO_DIR}/.git' || git clone '${REPO_URL}' '${REMOTE_REPO_DIR}'"
fi

# 5. Crear .env y generar secretos si hace falta --------------------------------
log_info "Paso 5/12: verificando archivo .env remoto..."
# NOTA DE DISEÑO: para este paso usamos `ssh ... bash -s <<'REMOTE_SCRIPT'` en
# vez de ssh_exec, porque necesitamos enviar un script remoto multilínea por
# stdin (heredoc con comillas simples en el delimitador para que NINGUNA
# variable se expanda localmente: todo $VAR se evalúa dentro de la VM). Los
# secretos generados (GF_SECURITY_ADMIN_PASSWORD, FAULT_ADMIN_TOKEN) se crean,
# usan y descartan enteramente dentro de la VM: nunca viajan de vuelta al
# operador ni se imprimen en este script.
env_setup_result="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${ADMIN_USER}@${PUBLIC_IP}" bash -s -- "${REMOTE_REPO_DIR}" <<'REMOTE_SCRIPT'
set -Eeuo pipefail
REPO_DIR="$1"
cd "${REPO_DIR}"
if [[ -f .env ]]; then
    echo "ENV_EXISTS"
    exit 0
fi
if [[ ! -f .env.example ]]; then
    echo "ENV_EXAMPLE_MISSING"
    exit 1
fi
cp .env.example .env

gen_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24
    else
        head -c32 /dev/urandom | base64
    fi
}

GF_PASS="$(gen_secret)"
FAULT_TOKEN="$(gen_secret)"

# El alfabeto base64 (A-Za-z0-9+/=) no contiene '#', por lo que es un
# delimitador seguro para sed sin riesgo de colisión con el secreto generado.
sed -i "s#^GF_SECURITY_ADMIN_PASSWORD=.*#GF_SECURITY_ADMIN_PASSWORD=${GF_PASS}#" .env
sed -i "s#^FAULT_ADMIN_TOKEN=.*#FAULT_ADMIN_TOKEN=${FAULT_TOKEN}#" .env

unset GF_PASS FAULT_TOKEN
echo "ENV_CREATED"
REMOTE_SCRIPT
)" || true
# `|| true` deliberado: el script remoto puede terminar con `exit 1` en el
# caso ENV_EXAMPLE_MISSING; sin este `|| true`, `set -e` abortaría aquí mismo
# y perderíamos el mensaje de error específico que armamos en el `case` de
# abajo (el trap ERR genérico solo diría "código 1", sin contexto).

case "${env_setup_result}" in
    ENV_EXISTS)
        log_info "El .env remoto ya existía; se conserva sin cambios (idempotente)."
        ;;
    ENV_CREATED)
        log_info ".env creado a partir de .env.example con secretos generados en la VM."
        ;;
    ENV_EXAMPLE_MISSING)
        log_error "No se encontró .env.example en el repo remoto; no se pudo crear .env."
        exit 1
        ;;
    *)
        log_error "Resultado inesperado al preparar .env remoto: '${env_setup_result}'"
        exit 1
        ;;
esac

# 6. Validar docker y docker compose --------------------------------------------
log_info "Paso 6/12: validando docker y docker compose remotos..."
ssh_exec "docker version >/dev/null" || { log_error "docker no responde en la VM (¿cloud-init instaló Docker?, ¿el usuario está en el grupo docker?)"; exit 1; }
ssh_exec "docker compose version >/dev/null" || { log_error "docker compose (plugin v2) no está disponible en la VM."; exit 1; }

# 7. docker compose config --quiet ----------------------------------------------
log_info "Paso 7/12: validando compose.yaml remoto (docker compose config --quiet)..."
ssh_repo "docker compose config --quiet"

# 8. Build --pull ----------------------------------------------------------------
log_info "Paso 8/12: construyendo imágenes (docker compose build --pull)... esto puede tardar varios minutos."
ssh_repo "docker compose build --pull"

# 9. up -d -------------------------------------------------------------------------
log_info "Paso 9/12: levantando el stack (docker compose up -d)..."
ssh_repo "docker compose up -d"

# 10. Esperar healthchecks -----------------------------------------------------------
log_info "Paso 10/12: esperando healthchecks de todos los contenedores (timeout ${HEALTH_TIMEOUT_SECONDS}s)..."
# NOTA DE DISEÑO: hacemos todo el polling en UN solo comando remoto (heredoc)
# en lugar de repetir `ssh_exec` cada 5s desde el operador, para evitar 60+
# conexiones SSH nuevas y reducir la sensibilidad a la latencia de red.
health_result="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${ADMIN_USER}@${PUBLIC_IP}" bash -s -- "${REMOTE_REPO_DIR}" "${HEALTH_TIMEOUT_SECONDS}" "${HEALTH_POLL_INTERVAL_SECONDS}" <<'REMOTE_SCRIPT'
set -Eeuo pipefail
REPO_DIR="$1"
TIMEOUT="$2"
INTERVAL="$3"
cd "${REPO_DIR}"
elapsed=0
while true; do
    # `|| true` deliberado: si `docker compose ps -q` falla (p. ej. el daemon
    # no responde), tratamos "sin ids" igual que "sin contenedores" y lo
    # reportamos explícitamente como NO_CONTAINERS más abajo, en vez de que
    # el `set -e` de este script remoto aborte sin diagnóstico.
    ids="$(docker compose ps -q || true)"
    if [[ -z "${ids}" ]]; then
        echo "NO_CONTAINERS"
        exit 1
    fi
    all_healthy=true
    unhealthy=""
    for id in ${ids}; do
        name="$(docker inspect --format '{{.Name}}' "${id}" | sed 's#^/##')"
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}sin-healthcheck{{end}}' "${id}")"
        if [[ "${status}" != "healthy" ]]; then
            all_healthy=false
            unhealthy="${unhealthy} ${name}:${status}"
        fi
    done
    if [[ "${all_healthy}" == "true" ]]; then
        echo "ALL_HEALTHY"
        exit 0
    fi
    if [[ "${elapsed}" -ge "${TIMEOUT}" ]]; then
        echo "TIMEOUT:${unhealthy}"
        exit 1
    fi
    sleep "${INTERVAL}"
    elapsed=$((elapsed + INTERVAL))
done
REMOTE_SCRIPT
)" || true
# (el `|| true` de arriba es deliberado: capturamos el resultado en la
# variable incluso si el script remoto termina con exit 1 por TIMEOUT, para
# poder reportar el detalle de qué contenedores quedaron mal; el chequeo real
# de éxito/fallo ocurre a continuación con el prefijo de la salida.)

case "${health_result}" in
    ALL_HEALTHY)
        log_info "Todos los contenedores están healthy."
        ;;
    NO_CONTAINERS*)
        log_error "docker compose ps no reportó contenedores; ¿falló 'docker compose up -d'?"
        exit 1
        ;;
    TIMEOUT:*)
        log_error "Timeout esperando healthchecks. Contenedores no saludables: ${health_result#TIMEOUT:}"
        log_error "Sugerencia: bash scripts/collect-diagnostics.sh"
        exit 1
        ;;
    *)
        log_error "Resultado inesperado esperando healthchecks: '${health_result}'"
        exit 1
        ;;
esac

# 11. Smoke tests locales dentro de la VM -----------------------------------------
log_info "Paso 11/12: ejecutando smoke tests dentro de la VM (TARGET_HOST=localhost)..."
# NOTA DE DISEÑO: reutilizamos scripts/smoke-test.sh (ya presente en el repo
# clonado dentro de la VM) en vez de duplicar su lógica de curl. Le pasamos
# TARGET_HOST=localhost porque, desde dentro de la VM, los puertos admin/
# Prometheus (9090) sí son alcanzables en localhost aunque no estén expuestos
# a Internet; smoke-test.sh detecta ese caso y agrega las validaciones extra.
ssh_exec "cd '${REMOTE_REPO_DIR}' && TARGET_HOST=localhost bash scripts/smoke-test.sh"

# 12. Imprimir URLs sin secretos ----------------------------------------------------
log_info "Paso 12/12: instalación remota completa."
echo
echo "== Laboratorio F13 disponible =="
echo "Aplicación / landing demo : http://${PUBLIC_IP}:8080"
echo "Grafana                   : http://${PUBLIC_IP}:3000"
echo "Jaeger                    : http://${PUBLIC_IP}:16686"
echo
echo "Los secretos (GF_SECURITY_ADMIN_PASSWORD, FAULT_ADMIN_TOKEN) NO se imprimen aquí."
echo "Para consultarlos manualmente (tú, no un script/CI), ejecuta:"
echo "  ssh ${ADMIN_USER}@${PUBLIC_IP} \"grep GF_SECURITY_ADMIN_PASSWORD ${REMOTE_REPO_DIR}/.env\""
echo "  ssh ${ADMIN_USER}@${PUBLIC_IP} \"grep FAULT_ADMIN_TOKEN ${REMOTE_REPO_DIR}/.env\""
