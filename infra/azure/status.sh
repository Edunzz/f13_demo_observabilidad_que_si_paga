#!/usr/bin/env bash
# ==============================================================================
# status.sh - Muestra el estado actual de la VM f13demo y sus recursos en Azure
# ==============================================================================
set -Eeuo pipefail
trap 'echo "ERROR en línea $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Uso: $(basename "$0") [-h|--help]

Muestra el estado actual de la VM de laboratorio f13demo:
  - Estado en Azure (az vm show) y power state (az vm get-instance-view)
  - IP pública actual
  - Reglas del NSG asociado
  - Comando SSH listo para copiar

Variables de entorno:
  STATE_FILE        Ruta al archivo de estado (default: ../../.f13demo-state.env
                     relativo a este script)
  RESOURCE_GROUP    (default: ace_JoseRomero)
  VM_NAME           (default: f13demo)
  ADMIN_USER        (default: azureuser)
  NSG_NAME          (default: f13demo-nsg)
  PUBLIC_IP_NAME    (default: f13demo-pip)

Nota: si existe el archivo de estado (generado por deploy.sh), sus valores
tienen prioridad sobre los defaults de arriba, porque se cargan (source)
antes de aplicar esos defaults con \${VAR:-default}.
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    *) echo "Argumento desconocido: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

# Cargar estado guardado por deploy.sh, si existe.
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/../../.f13demo-state.env}"
if [[ -f "$STATE_FILE" ]]; then
  echo "Cargando estado desde $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

RESOURCE_GROUP="${RESOURCE_GROUP:-ace_JoseRomero}"
VM_NAME="${VM_NAME:-f13demo}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
NSG_NAME="${NSG_NAME:-f13demo-nsg}"
PUBLIC_IP_NAME="${PUBLIC_IP_NAME:-f13demo-pip}"

echo "=== VM '$VM_NAME' (resource group '$RESOURCE_GROUP') ==="
if ! az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" -o table 2>/dev/null; then
  echo "La VM '$VM_NAME' no existe en el resource group '$RESOURCE_GROUP'." >&2
  exit 1
fi

echo
echo "=== Power state ==="
POWER_STATE="$(az vm get-instance-view --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
  --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" -o tsv)"
echo "Estado: ${POWER_STATE:-desconocido}"

echo
echo "=== IP pública actual ('$PUBLIC_IP_NAME') ==="
PUBLIC_IP="$(az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$PUBLIC_IP_NAME" \
  --query ipAddress -o tsv 2>/dev/null || true)"
echo "IP pública: ${PUBLIC_IP:-sin asignar}"

echo
echo "=== Reglas del NSG '$NSG_NAME' ==="
az network nsg rule list --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
  --query "[].{name:name, priority:priority, access:access, direction:direction, protocol:protocol, source:sourceAddressPrefix, port:destinationPortRange}" \
  -o table 2>/dev/null || echo "No se encontró el NSG '$NSG_NAME' o no tiene reglas."

echo
echo "=== Comando SSH ==="
if [[ -n "${PUBLIC_IP:-}" ]]; then
  if [[ -n "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
    echo "ssh -i ${SSH_PRIVATE_KEY_PATH} ${ADMIN_USER}@${PUBLIC_IP}"
  else
    echo "ssh ${ADMIN_USER}@${PUBLIC_IP}"
  fi
else
  echo "No hay IP pública asignada todavía (la VM puede estar desasignada/deallocated)."
fi
