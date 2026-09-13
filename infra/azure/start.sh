#!/usr/bin/env bash
# ==============================================================================
# start.sh - Enciende la VM f13demo y valida conectividad
# ==============================================================================
set -Eeuo pipefail
trap 'echo "ERROR en línea $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Uso: $(basename "$0") [-h|--help]

Enciende la VM de laboratorio f13demo (az vm start), espera a que quede en
estado 'running' y valida conectividad TCP/22 y SSH real con reintentos.

Variables de entorno:
  STATE_FILE      Ruta al archivo de estado (default: ../../.f13demo-state.env
                   relativo a este script)
  RESOURCE_GROUP  (default: ace_JoseRomero)
  VM_NAME         (default: f13demo)
  ADMIN_USER      (default: azureuser)
  PUBLIC_IP_NAME  (default: f13demo-pip)

Nota: si existe el archivo de estado (generado por deploy.sh), sus valores
tienen prioridad sobre los defaults de arriba (se cargan antes de aplicarlos).
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    *) echo "Argumento desconocido: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/../../.f13demo-state.env}"
if [[ -f "$STATE_FILE" ]]; then
  echo "Cargando estado desde $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

RESOURCE_GROUP="${RESOURCE_GROUP:-ace_JoseRomero}"
VM_NAME="${VM_NAME:-f13demo}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
PUBLIC_IP_NAME="${PUBLIC_IP_NAME:-f13demo-pip}"

# Chequeo TCP portable (sin `nc` ni `timeout` externo), igual que en deploy.sh.
tcp_check() {
  local host="$1" port="$2" timeout_s="${3:-5}"
  ( exec 3<>"/dev/tcp/${host}/${port}" ) 2>/dev/null &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if (( waited >= timeout_s )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 1
    fi
  done
  wait "$pid"
}

echo "Encendiendo VM '$VM_NAME' (resource group '$RESOURCE_GROUP')..."
az vm start --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" -o none

echo "Esperando a que la VM esté en estado 'running'..."
MAX_WAIT=300
INTERVAL=10
ELAPSED=0
STATE=""
while (( ELAPSED < MAX_WAIT )); do
  STATE="$(az vm get-instance-view --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" -o tsv)"
  if [[ "$STATE" == "PowerState/running" ]]; then
    echo "VM en estado running."
    break
  fi
  echo "  estado actual: ${STATE:-desconocido}. Reintentando en ${INTERVAL}s..."
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done
if [[ "$STATE" != "PowerState/running" ]]; then
  echo "ERROR: timeout (${MAX_WAIT}s) esperando que la VM entre en estado running." >&2
  exit 1
fi

PUBLIC_IP="$(az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$PUBLIC_IP_NAME" --query ipAddress -o tsv)"
echo "IP pública: $PUBLIC_IP"

echo "Verificando conectividad TCP al puerto 22..."
TCP_OK=0
for attempt in $(seq 1 10); do
  if tcp_check "$PUBLIC_IP" 22 5; then
    TCP_OK=1
    echo "Puerto 22 accesible."
    break
  fi
  echo "  intento $attempt/10: puerto 22 no responde aún. Esperando 15s..."
  sleep 15
done
if [[ "$TCP_OK" -ne 1 ]]; then
  echo "ERROR: no se pudo conectar por TCP al puerto 22 tras varios intentos." >&2
  exit 1
fi

# SSH_PRIVATE_KEY_PATH lo escribe deploy.sh en el estado (derivado de
# SSH_PUBLIC_KEY_PATH, sin el sufijo .pub). Sin `-i` explícito, ssh solo
# prueba rutas por defecto (id_rsa/id_ecdsa/id_ed25519) o un ssh-agent
# cargado, y falla si la clave del laboratorio tiene otro nombre.
_SSH_IDENTITY_OPTS=()
if [[ -n "${SSH_PRIVATE_KEY_PATH:-}" && -f "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
  _SSH_IDENTITY_OPTS=(-i "$SSH_PRIVATE_KEY_PATH")
fi

echo "Verificando SSH real..."
SSH_OK=0
for attempt in $(seq 1 10); do
  if ssh "${_SSH_IDENTITY_OPTS[@]}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
       "${ADMIN_USER}@${PUBLIC_IP}" 'echo ok' &>/dev/null; then
    SSH_OK=1
    echo "SSH OK."
    break
  fi
  echo "  intento $attempt/10: SSH no disponible aún. Esperando 15s..."
  sleep 15
done
if [[ "$SSH_OK" -ne 1 ]]; then
  echo "ERROR: no se pudo conectar por SSH tras varios intentos." >&2
  exit 1
fi

echo
echo "VM '$VM_NAME' arriba y accesible."
if [[ -n "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
  echo "ssh -i ${SSH_PRIVATE_KEY_PATH} ${ADMIN_USER}@${PUBLIC_IP}"
else
  echo "ssh ${ADMIN_USER}@${PUBLIC_IP}"
fi
