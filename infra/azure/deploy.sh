#!/usr/bin/env bash
# ==============================================================================
# deploy.sh - Aprovisiona la VM de laboratorio "f13demo" en Azure
#
# Suscripción objetivo: Dynatrace-DXS/LATAM
# Resource group EXISTENTE (no se crea): ace_JoseRomero (región eastus)
#
# Este script es idempotente: se puede volver a correr y reutiliza los
# recursos ya creados en vez de duplicarlos o recrearlos.
# ==============================================================================
set -Eeuo pipefail
trap 'echo "ERROR en línea $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Variables de configuración (todas admiten override por variable de entorno)
# ------------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-ace_JoseRomero}"
VM_NAME="${VM_NAME:-f13demo}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
VM_SIZE="${VM_SIZE:-Standard_D4s_v5}"
IMAGE="${IMAGE:-Ubuntu2404}"
VNET_NAME="${VNET_NAME:-f13demo-vnet}"
SUBNET_NAME="${SUBNET_NAME:-f13demo-subnet}"
NSG_NAME="${NSG_NAME:-f13demo-nsg}"
PUBLIC_IP_NAME="${PUBLIC_IP_NAME:-f13demo-pip}"
NIC_NAME="${NIC_NAME:-f13demo-nic}"
OS_DISK_NAME="${OS_DISK_NAME:-f13demo-osdisk}"
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
AZURE_LOCATION="${AZURE_LOCATION:-}"   # si vacío, se toma la location del resource group
ADMIN_CIDR="${ADMIN_CIDR:-}"           # si vacío, se calcula IP pública actual /32
AUTO_SHUTDOWN_TIME="${AUTO_SHUTDOWN_TIME:-1900}"       # HHMM
AUTO_SHUTDOWN_TIMEZONE="${AUTO_SHUTDOWN_TIMEZONE:-America/Bogota}"

# Array (no string) para que las expansiones "${TAGS[@]}" mas abajo pasen cada
# tag como un argumento separado a `az`, sin depender de word-splitting
# implicito sobre una variable sin comillas (shellcheck SC2086).
TAGS=(project=f13-demo owner=JoseRomero purpose=observabilidad-que-si-paga environment=demo)

# Lista fija de tamaños equivalentes a probar si VM_SIZE no está disponible en
# la región (Paso 4). Se registra siempre cuál se usó y por qué.
FALLBACK_SIZES=(Standard_D4s_v5 Standard_D4as_v5 Standard_D4s_v4 Standard_D4_v5 Standard_D4d_v5)

usage() {
  cat <<EOF
Uso: $(basename "$0") [-h|--help]

Aprovisiona (de forma idempotente) la VM de laboratorio f13demo dentro del
resource group EXISTENTE \$RESOURCE_GROUP. Este script NUNCA crea el resource
group; si no existe, termina con error.

Variables de entorno (todas con default, todas sobreescribibles):
  RESOURCE_GROUP          Resource group existente (default: ace_JoseRomero)
  VM_NAME                 Nombre de la VM (default: f13demo)
  ADMIN_USER              Usuario admin Linux (default: azureuser)
  VM_SIZE                 Tamaño de VM deseado (default: Standard_D4s_v5)
  IMAGE                   Alias de imagen (default: Ubuntu2404)
  VNET_NAME               (default: f13demo-vnet)
  SUBNET_NAME             (default: f13demo-subnet)
  NSG_NAME                (default: f13demo-nsg)
  PUBLIC_IP_NAME          (default: f13demo-pip)
  NIC_NAME                (default: f13demo-nic)
  OS_DISK_NAME            (default: f13demo-osdisk)
  SSH_PUBLIC_KEY_PATH     Ruta a clave pública SSH (default: \$HOME/.ssh/id_ed25519.pub)
                          Si no existe, el script termina; no genera claves ni
                          adivina otra ruta salvo que la definas explícitamente.
  AZURE_LOCATION          Región a usar (default: la del resource group)
  ADMIN_CIDR              CIDR IPv4 admitido en el NSG (default: IP pública
                          actual del operador /32, autodetectada)
  AUTO_SHUTDOWN_TIME      Hora de auto-apagado HHMM (default: 1900)
  AUTO_SHUTDOWN_TIMEZONE  Zona horaria del auto-apagado (default: America/Bogota)

Pasos que ejecuta (en orden): ver comentarios "# Paso N:" dentro del script.
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    *) echo "Argumento desconocido: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

# ------------------------------------------------------------------------------
# Utilidades
# ------------------------------------------------------------------------------

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: falta el comando requerido '$1'. Instálalo antes de continuar." >&2
    exit 1
  fi
}

# Valida que un string tenga forma de CIDR IPv4 (octetos 0-255, prefijo 0-32).
is_valid_cidr() {
  local cidr="$1" ip prefix o1 o2 o3 o4 o
  [[ "$cidr" == */* ]] || return 1
  ip="${cidr%/*}"
  prefix="${cidr#*/}"
  [[ "$prefix" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  [[ -n "${o1:-}" && -n "${o2:-}" && -n "${o3:-}" && -n "${o4:-}" ]] || return 1
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

# Chequeo TCP portable sin depender de `nc` ni del binario externo `timeout`
# (no siempre disponible bajo Git Bash en Windows). Usa el redireccionamiento
# /dev/tcp propio de bash, en background, con un límite de espera manual.
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

# ------------------------------------------------------------------------------
# Verificación de dependencias locales (previo a los pasos numerados)
# ------------------------------------------------------------------------------
echo "Verificando dependencias locales (az, curl, ssh)..."
require_cmd az
require_cmd curl
require_cmd ssh
# Decisión de diseño: este script NO depende de jq. jq puede no estar instalado
# en la máquina del operador (p. ej. Windows con solo Git Bash + az CLI), así
# que todas las consultas a resultados de az CLI usan '--query <JMESPath> -o tsv'
# en lugar de parsear JSON con jq. Si jq está disponible no se usa igual, para
# mantener un único código path.
if ! command -v jq >/dev/null 2>&1; then
  echo "(jq no está instalado; no hace falta, este script usa --query/-o tsv de az CLI.)"
fi

# ==============================================================================
# Paso 1: mostrar la suscripción activa de Azure CLI
# ==============================================================================
echo
echo "=== Paso 1: suscripción activa ==="
SUB_NAME="$(az account show --query name -o tsv)"
SUB_ID="$(az account show --query id -o tsv)"
echo "Suscripción activa: $SUB_NAME ($SUB_ID)"

# ==============================================================================
# Paso 2: verificar que el resource group EXISTENTE existe (nunca se crea aquí)
# ==============================================================================
echo
echo "=== Paso 2: verificando resource group '$RESOURCE_GROUP' ==="
if ! az group show --name "$RESOURCE_GROUP" -o none 2>/dev/null; then
  echo "ERROR: el resource group '$RESOURCE_GROUP' no existe o no es accesible con la suscripción activa ($SUB_NAME)." >&2
  echo "Este script NO crea resource groups. Verifica el nombre, o cambia de suscripción con 'az account set --subscription ...'." >&2
  exit 1
fi
LOCATION="${AZURE_LOCATION:-$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)}"
echo "Resource group OK. Región usada: $LOCATION"

# ==============================================================================
# Paso 3: validar clave SSH pública y CIDR del operador
# ==============================================================================
echo
echo "=== Paso 3: validando clave SSH y CIDR de acceso ==="
if [[ ! -f "$SSH_PUBLIC_KEY_PATH" ]]; then
  echo "ERROR: no se encontró la clave pública SSH en '$SSH_PUBLIC_KEY_PATH'." >&2
  echo "Este script no genera claves nuevas ni adivina otra ruta. Genera una con:" >&2
  echo "  ssh-keygen -t ed25519 -f \"\$HOME/.ssh/id_ed25519\"" >&2
  echo "o define SSH_PUBLIC_KEY_PATH apuntando a una clave pública existente." >&2
  exit 1
fi
if ! grep -q '^ssh-' "$SSH_PUBLIC_KEY_PATH"; then
  echo "ERROR: '$SSH_PUBLIC_KEY_PATH' no parece una clave pública SSH válida (no empieza con 'ssh-')." >&2
  exit 1
fi
echo "Clave SSH pública OK: $SSH_PUBLIC_KEY_PATH"

if [[ -n "$ADMIN_CIDR" ]]; then
  if ! is_valid_cidr "$ADMIN_CIDR"; then
    echo "ERROR: ADMIN_CIDR='$ADMIN_CIDR' no tiene formato CIDR IPv4 válido (ej. 203.0.113.5/32)." >&2
    exit 1
  fi
  echo "Usando ADMIN_CIDR explícito: $ADMIN_CIDR"
else
  echo "ADMIN_CIDR no definido, detectando IP pública actual del operador..."
  MY_IP="$(curl -s --max-time 5 https://ifconfig.me || true)"
  if [[ -z "$MY_IP" ]]; then
    echo "  ifconfig.me no respondió, probando con api.ipify.org..."
    MY_IP="$(curl -s --max-time 5 https://api.ipify.org || true)"
  fi
  if [[ -z "$MY_IP" ]] || ! is_valid_cidr "${MY_IP}/32"; then
    echo "ERROR: no se pudo determinar automáticamente la IP pública del operador (ifconfig.me y api.ipify.org fallaron)." >&2
    echo "Define ADMIN_CIDR manualmente, ej.: ADMIN_CIDR=203.0.113.5/32 ./deploy.sh" >&2
    exit 1
  fi
  ADMIN_CIDR="${MY_IP}/32"
  echo "IP pública detectada: $MY_IP -> ADMIN_CIDR=$ADMIN_CIDR"
fi

# ==============================================================================
# Paso 4: verificar disponibilidad del tamaño de VM en la región (con fallback)
# ==============================================================================
echo
echo "=== Paso 4: verificando disponibilidad de tamaño de VM en '$LOCATION' ==="
RESOLVED_VM_SIZE=""
# Construimos la lista de candidatos: primero el VM_SIZE pedido, luego el
# fallback fijo, sin duplicados (si VM_SIZE ya es el default, no se prueba dos veces).
CANDIDATES=("$VM_SIZE")
for s in "${FALLBACK_SIZES[@]}"; do
  dup=0
  for existing in "${CANDIDATES[@]}"; do [[ "$existing" == "$s" ]] && dup=1 && break; done
  [[ "$dup" -eq 0 ]] && CANDIDATES+=("$s")
done

for size in "${CANDIDATES[@]}"; do
  echo "Verificando '$size'..."
  AVAILABLE="$(az vm list-skus --location "$LOCATION" --size "$size" --resource-type virtualMachines \
    --query "[?name=='$size' && length(restrictions)==\`0\`].name | [0]" -o tsv 2>/dev/null || true)"
  if [[ -n "$AVAILABLE" && "$AVAILABLE" != "None" ]]; then
    RESOLVED_VM_SIZE="$size"
    if [[ "$size" != "$VM_SIZE" ]]; then
      echo "Aviso: '$VM_SIZE' no está disponible (o tiene restricciones) en '$LOCATION'."
      echo "Se usará '$size' en su lugar: primer tamaño equivalente disponible de la lista de fallback (${CANDIDATES[*]})."
    else
      echo "'$size' disponible en '$LOCATION'."
    fi
    break
  fi
done
if [[ -z "$RESOLVED_VM_SIZE" ]]; then
  echo "ERROR: ninguno de los tamaños candidatos (${CANDIDATES[*]}) está disponible en '$LOCATION'." >&2
  exit 1
fi
echo "Tamaño de VM a usar: $RESOLVED_VM_SIZE"

# ==============================================================================
# Paso 5: crear (idempotente) VNet 10.13.0.0/16 con subnet 10.13.1.0/24
# ==============================================================================
echo
echo "=== Paso 5: VNet/subnet ==="
if az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" -o none 2>/dev/null; then
  echo "VNet '$VNET_NAME' ya existe, se reutiliza."
else
  echo "Creando VNet '$VNET_NAME' (10.13.0.0/16) con subnet '$SUBNET_NAME' (10.13.1.0/24)..."
  az network vnet create \
    --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" --location "$LOCATION" \
    --address-prefix 10.13.0.0/16 \
    --subnet-name "$SUBNET_NAME" --subnet-prefix 10.13.1.0/24 \
    --tags "${TAGS[@]}" \
    -o none
fi
if ! az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_NAME" -o none 2>/dev/null; then
  echo "Creando subnet '$SUBNET_NAME' dentro de la VNet existente..."
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_NAME" \
    --address-prefix 10.13.1.0/24 \
    -o none
fi

# ==============================================================================
# Paso 6: crear (idempotente) NSG con reglas de entrada solo desde $ADMIN_CIDR
# ==============================================================================
echo
echo "=== Paso 6: NSG '$NSG_NAME' ==="
RULE_NAMES=(Allow-SSH-Admin Allow-App-Admin Allow-Grafana-Admin Allow-Jaeger-Admin)
RULE_PORTS=(22 8080 3000 16686)
RULE_PRIORITIES=(100 110 120 130)

create_nsg_rule() {
  local name="$1" port="$2" priority="$3"
  echo "  Creando regla '$name' (puerto $port, prioridad $priority, origen $ADMIN_CIDR)..."
  az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$name" \
    --priority "$priority" --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "$ADMIN_CIDR" --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges "$port" \
    -o none
}

if az network nsg show --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" -o none 2>/dev/null; then
  echo "NSG '$NSG_NAME' ya existe. Verificando que sus reglas coincidan con lo esperado..."
  for i in "${!RULE_NAMES[@]}"; do
    name="${RULE_NAMES[$i]}"
    expected_port="${RULE_PORTS[$i]}"
    expected_priority="${RULE_PRIORITIES[$i]}"

    if ! az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$name" -o none 2>/dev/null; then
      echo "ERROR: el NSG '$NSG_NAME' ya existe pero le falta la regla esperada '$name' (puerto $expected_port)." >&2
      echo "Este script no crea reglas nuevas sobre un NSG preexistente con configuración distinta a la esperada." >&2
      echo "Revisa manualmente el NSG o bórralo y vuelve a correr deploy.sh." >&2
      exit 1
    fi

    cur_port="$(az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$name" --query destinationPortRange -o tsv)"
    cur_priority="$(az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$name" --query priority -o tsv)"
    cur_access="$(az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$name" --query access -o tsv)"
    cur_direction="$(az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$name" --query direction -o tsv)"
    cur_protocol="$(az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$name" --query protocol -o tsv)"
    cur_src="$(az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$name" --query sourceAddressPrefix -o tsv)"
    if [[ -z "$cur_src" || "$cur_src" == "None" ]]; then
      cur_src="$(az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$name" --query "join(',', sourceAddressPrefixes)" -o tsv 2>/dev/null || true)"
    fi

    if [[ "$cur_port" != "$expected_port" || "$cur_priority" != "$expected_priority" || \
          "$cur_access" != "Allow" || "$cur_direction" != "Inbound" || "$cur_protocol" != "Tcp" ]]; then
      echo "ERROR: la regla '$name' del NSG '$NSG_NAME' existe pero difiere de lo esperado:" >&2
      echo "  esperado -> puerto=$expected_port prioridad=$expected_priority access=Allow direction=Inbound protocol=Tcp" >&2
      echo "  actual   -> puerto=$cur_port prioridad=$cur_priority access=$cur_access direction=$cur_direction protocol=$cur_protocol" >&2
      echo "No se sobreescribe automáticamente. Ajusta el NSG manualmente o elimina la regla y vuelve a correr el script." >&2
      exit 1
    fi

    if [[ "$cur_src" != "$ADMIN_CIDR" ]]; then
      # Única actualización automática permitida: la IP pública del operador cambió
      # desde el último deploy. Esto es un cambio esperado y sí se aplica.
      echo "La IP del operador cambió ('$cur_src' -> '$ADMIN_CIDR'). Actualizando origen de la regla '$name'..."
      az network nsg rule update -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$name" \
        --source-address-prefixes "$ADMIN_CIDR" -o none
    else
      echo "Regla '$name' OK (sin cambios)."
    fi
  done
else
  echo "Creando NSG '$NSG_NAME'..."
  az network nsg create \
    --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" --location "$LOCATION" \
    --tags "${TAGS[@]}" \
    -o none
  for i in "${!RULE_NAMES[@]}"; do
    create_nsg_rule "${RULE_NAMES[$i]}" "${RULE_PORTS[$i]}" "${RULE_PRIORITIES[$i]}"
  done
fi

# ==============================================================================
# Paso 7: crear (idempotente) IP pública Standard, asignación estática
# ==============================================================================
echo
echo "=== Paso 7: IP pública '$PUBLIC_IP_NAME' ==="
if az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$PUBLIC_IP_NAME" -o none 2>/dev/null; then
  echo "IP pública '$PUBLIC_IP_NAME' ya existe, se reutiliza."
else
  echo "Creando IP pública '$PUBLIC_IP_NAME' (Standard, Static)..."
  az network public-ip create \
    --resource-group "$RESOURCE_GROUP" --name "$PUBLIC_IP_NAME" --location "$LOCATION" \
    --sku Standard --allocation-method Static \
    --tags "${TAGS[@]}" \
    -o none
fi

# ==============================================================================
# Paso 8: crear (idempotente) NIC asociada al NSG y a la subnet
# ==============================================================================
echo
echo "=== Paso 8: NIC '$NIC_NAME' ==="
if az network nic show --resource-group "$RESOURCE_GROUP" --name "$NIC_NAME" -o none 2>/dev/null; then
  echo "NIC '$NIC_NAME' ya existe, se reutiliza."
else
  echo "Creando NIC '$NIC_NAME'..."
  az network nic create \
    --resource-group "$RESOURCE_GROUP" --name "$NIC_NAME" --location "$LOCATION" \
    --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME" \
    --public-ip-address "$PUBLIC_IP_NAME" \
    --tags "${TAGS[@]}" \
    -o none
fi

# ==============================================================================
# Paso 9: crear (idempotente) la VM Ubuntu 24.04 LTS
# ==============================================================================
echo
echo "=== Paso 9: VM '$VM_NAME' ==="
if az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" -o none 2>/dev/null; then
  echo "La VM '$VM_NAME' ya existe. Validando compatibilidad antes de reutilizarla..."
  EXISTING_SIZE="$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query "hardwareProfile.vmSize" -o tsv)"
  EXISTING_SKU="$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query "storageProfile.imageReference.sku" -o tsv)"
  if [[ "$EXISTING_SIZE" != "$RESOLVED_VM_SIZE" ]]; then
    echo "ERROR: la VM '$VM_NAME' existe con tamaño '$EXISTING_SIZE', distinto al esperado '$RESOLVED_VM_SIZE'." >&2
    echo "No se recrea automáticamente. Borra la VM (destroy-lab-resources.sh) o ajusta VM_SIZE para que coincida." >&2
    exit 1
  fi
  if [[ "$EXISTING_SKU" != *"24_04"* && "$EXISTING_SKU" != *"24.04"* ]]; then
    echo "ERROR: la VM '$VM_NAME' existe pero su imagen (sku='$EXISTING_SKU') no parece Ubuntu 24.04." >&2
    echo "No se recrea automáticamente para evitar pérdida de datos. Revisa manualmente." >&2
    exit 1
  fi
  echo "VM existente compatible (tamaño=$EXISTING_SIZE, sku=$EXISTING_SKU). Se reutiliza."
else
  echo "Creando VM '$VM_NAME' (Ubuntu 24.04, tamaño $RESOLVED_VM_SIZE)..."
  az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --location "$LOCATION" \
    --size "$RESOLVED_VM_SIZE" \
    --image "$IMAGE" \
    --nics "$NIC_NAME" \
    --os-disk-name "$OS_DISK_NAME" \
    --storage-sku Premium_LRS \
    --os-disk-size-gb 64 \
    --admin-username "$ADMIN_USER" \
    --ssh-key-values "$SSH_PUBLIC_KEY_PATH" \
    --authentication-type ssh \
    --custom-data "$SCRIPT_DIR/cloud-init.yaml" \
    --tags "${TAGS[@]}" \
    -o none
fi

# ==============================================================================
# Paso 10: configurar auto-shutdown
# ==============================================================================
echo
echo "=== Paso 10: auto-shutdown ==="
echo "Configurando apagado automático a las $AUTO_SHUTDOWN_TIME ($AUTO_SHUTDOWN_TIMEZONE)..."
az vm auto-shutdown \
  --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
  --time "$AUTO_SHUTDOWN_TIME" --timezone "$AUTO_SHUTDOWN_TIMEZONE" \
  -o none

# ==============================================================================
# Paso 11: esperar a que la VM esté en estado 'running'
# ==============================================================================
echo
echo "=== Paso 11: esperando estado running ==="
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

# ==============================================================================
# Paso 12: verificar conectividad TCP/22 y SSH real, con reintentos
# ==============================================================================
echo
echo "=== Paso 12: verificando conectividad ==="
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
  echo "ERROR: no se pudo establecer conexión TCP al puerto 22 tras varios intentos." >&2
  exit 1
fi

echo "Verificando SSH real..."
SSH_OK=0
for attempt in $(seq 1 10); do
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
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

# ==============================================================================
# Paso 13: guardar estado en la raíz del repo (../../.f13demo-state.env)
# ==============================================================================
echo
echo "=== Paso 13: guardando estado ==="
STATE_FILE="$SCRIPT_DIR/../../.f13demo-state.env"
{
  echo "RESOURCE_GROUP=$RESOURCE_GROUP"
  echo "VM_NAME=$VM_NAME"
  echo "PUBLIC_IP=$PUBLIC_IP"
  echo "ADMIN_USER=$ADMIN_USER"
  echo "VNET_NAME=$VNET_NAME"
  echo "SUBNET_NAME=$SUBNET_NAME"
  echo "NSG_NAME=$NSG_NAME"
  echo "PUBLIC_IP_NAME=$PUBLIC_IP_NAME"
  echo "NIC_NAME=$NIC_NAME"
  echo "ADMIN_CIDR=$ADMIN_CIDR"
} > "$STATE_FILE"
echo "Estado guardado en $STATE_FILE (sin secretos, ya está en .gitignore)."

# ==============================================================================
# Paso 14: imprimir comando SSH y URLs de acceso
# ==============================================================================
echo
echo "=== Paso 14: acceso ==="
echo "Comando SSH:"
echo "  ssh ${ADMIN_USER}@${PUBLIC_IP}"
echo
echo "URLs (una vez que el stack esté levantado en la VM):"
echo "  App:     http://${PUBLIC_IP}:8080"
echo "  Grafana: http://${PUBLIC_IP}:3000"
echo "  Jaeger:  http://${PUBLIC_IP}:16686"
echo
echo "Deploy completo."
