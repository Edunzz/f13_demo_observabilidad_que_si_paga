#!/usr/bin/env bash
# ==============================================================================
# stop.sh - Desasigna (deallocate) la VM f13demo para detener la facturación
#            de cómputo
# ==============================================================================
set -Eeuo pipefail
trap 'echo "ERROR en línea $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ASSUME_YES=0

usage() {
  cat <<EOF
Uso: $(basename "$0") [-h|--help] [--yes]

Desasigna (az vm deallocate) la VM de laboratorio f13demo. IMPORTANTE:
'deallocate' libera el hardware asignado y detiene la facturación de cómputo
de la VM; esto es distinto de apagar solo el sistema operativo desde dentro
de la VM (shutdown/poweroff), lo cual deja la VM en estado 'stopped' pero
SIGUE facturando el cómputo reservado. El disco administrado sigue
facturándose en ambos casos.

Opciones:
  --yes       No pedir confirmación interactiva.
  -h, --help  Muestra esta ayuda.

Variables de entorno:
  STATE_FILE      Ruta al archivo de estado (default: ../../.f13demo-state.env
                   relativo a este script)
  RESOURCE_GROUP  (default: ace_JoseRomero)
  VM_NAME         (default: f13demo)
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --yes) ASSUME_YES=1 ;;
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

if [[ "$ASSUME_YES" -ne 1 ]]; then
  echo "Vas a desasignar (deallocate) la VM '$VM_NAME' en el resource group '$RESOURCE_GROUP'."
  echo "Esto detiene la facturación de cómputo (distinto de apagar solo el SO, que seguiría facturando el cómputo reservado)."
  read -r -p "¿Confirmas? Escribe 'si' para continuar: " CONFIRM
  if [[ "$CONFIRM" != "si" ]]; then
    echo "Cancelado. No se hizo nada."
    exit 1
  fi
fi

echo "Desasignando VM '$VM_NAME'..."
az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"
echo "VM desasignada. La facturación de cómputo se detuvo (el disco administrado sigue facturándose)."
