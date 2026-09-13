#!/usr/bin/env bash
# ==============================================================================
# destroy-lab-resources.sh - Borra los recursos individuales del laboratorio
#                            f13demo. NUNCA borra el resource group.
# ==============================================================================
set -Eeuo pipefail
trap 'echo "ERROR en línea $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ASSUME_YES=0

usage() {
  cat <<EOF
Uso: $(basename "$0") [-h|--help] [--yes]

Borra, uno por uno y por nombre exacto, los recursos del laboratorio f13demo
dentro del resource group EXISTENTE \$RESOURCE_GROUP:
  1. VM             (\$VM_NAME)
  2. NIC             (\$NIC_NAME)
  3. Disco OS        (\$OS_DISK_NAME)
  4. IP pública      (\$PUBLIC_IP_NAME)
  5. NSG             (\$NSG_NAME)
  6. VNet            (\$VNET_NAME)

Bajo NINGUNA circunstancia este script ejecuta 'az group delete' ni borra
\$RESOURCE_GROUP (ace_JoseRomero); solo borra los recursos individuales de
arriba, y solo si su nombre tiene el prefijo 'f13demo'.

Opciones:
  --yes       No pedir la confirmación escrita 'f13demo' (úsalo con cuidado).
  -h, --help  Muestra esta ayuda.

Variables de entorno:
  STATE_FILE      Ruta al archivo de estado (default: ../../.f13demo-state.env
                   relativo a este script)
  RESOURCE_GROUP  (default: ace_JoseRomero)
  VM_NAME         (default: f13demo)
  NIC_NAME        (default: f13demo-nic)
  OS_DISK_NAME    (default: f13demo-osdisk)
  PUBLIC_IP_NAME  (default: f13demo-pip)
  NSG_NAME        (default: f13demo-nsg)
  VNET_NAME       (default: f13demo-vnet)
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
NIC_NAME="${NIC_NAME:-f13demo-nic}"
# OS_DISK_NAME no se guarda en el archivo de estado (deploy.sh no lo persiste),
# por eso siempre cae al default salvo que se pase explícito por entorno.
OS_DISK_NAME="${OS_DISK_NAME:-f13demo-osdisk}"
PUBLIC_IP_NAME="${PUBLIC_IP_NAME:-f13demo-pip}"
NSG_NAME="${NSG_NAME:-f13demo-nsg}"
VNET_NAME="${VNET_NAME:-f13demo-vnet}"

# Salvaguarda: todos los nombres a borrar deben tener el prefijo f13demo.
# Si alguna variable fue sobreescrita apuntando a otra cosa, abortamos antes
# de borrar nada, para no arriesgar recursos ajenos al laboratorio dentro
# del mismo resource group.
for name in "$VM_NAME" "$NIC_NAME" "$OS_DISK_NAME" "$PUBLIC_IP_NAME" "$NSG_NAME" "$VNET_NAME"; do
  if [[ "$name" != f13demo* ]]; then
    echo "ERROR: '$name' no tiene el prefijo 'f13demo'. Por seguridad, este script solo borra recursos con ese prefijo." >&2
    exit 1
  fi
done

echo "=================================================================="
echo "Se van a borrar estos recursos del resource group '$RESOURCE_GROUP':"
echo "  1. VM:          $VM_NAME"
echo "  2. NIC:         $NIC_NAME"
echo "  3. Disco OS:    $OS_DISK_NAME"
echo "  4. IP pública:  $PUBLIC_IP_NAME"
echo "  5. NSG:         $NSG_NAME"
echo "  6. VNet:        $VNET_NAME"
echo
echo "El resource group '$RESOURCE_GROUP' NO se borra (este script nunca ejecuta 'az group delete')."
echo "=================================================================="

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Escribe literalmente 'f13demo' para confirmar el borrado: " CONFIRM
  if [[ "$CONFIRM" != "f13demo" ]]; then
    echo "Confirmación incorrecta. Cancelado, no se borró nada."
    exit 1
  fi
fi

echo
echo "Paso 1/6: borrando VM '$VM_NAME'..."
az vm delete --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --yes -o none 2>/dev/null \
  && echo "VM borrada." || echo "La VM '$VM_NAME' no existía o ya fue borrada."

echo "Paso 2/6: borrando NIC '$NIC_NAME'..."
az network nic delete --resource-group "$RESOURCE_GROUP" --name "$NIC_NAME" -o none 2>/dev/null \
  && echo "NIC borrada." || echo "La NIC '$NIC_NAME' no existía o ya fue borrada."

echo "Paso 3/6: borrando disco OS '$OS_DISK_NAME'..."
az disk delete --resource-group "$RESOURCE_GROUP" --name "$OS_DISK_NAME" --yes -o none 2>/dev/null \
  && echo "Disco borrado." || echo "El disco '$OS_DISK_NAME' no existía o ya fue borrado."

echo "Paso 4/6: borrando IP pública '$PUBLIC_IP_NAME'..."
az network public-ip delete --resource-group "$RESOURCE_GROUP" --name "$PUBLIC_IP_NAME" -o none 2>/dev/null \
  && echo "IP pública borrada." || echo "La IP pública '$PUBLIC_IP_NAME' no existía o ya fue borrada."

echo "Paso 5/6: borrando NSG '$NSG_NAME'..."
az network nsg delete --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" -o none 2>/dev/null \
  && echo "NSG borrado." || echo "El NSG '$NSG_NAME' no existía o ya fue borrado."

echo "Paso 6/6: borrando VNet '$VNET_NAME'..."
az network vnet delete --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" -o none 2>/dev/null \
  && echo "VNet borrada." || echo "La VNet '$VNET_NAME' no existía o ya fue borrada."

echo
echo "Listo. Recursos individuales del laboratorio f13demo borrados en '$RESOURCE_GROUP'."
echo "El resource group '$RESOURCE_GROUP' NO fue tocado."

if [[ -f "$STATE_FILE" ]]; then
  echo "Puedes borrar manualmente el archivo de estado si ya no lo necesitas: $STATE_FILE"
fi
