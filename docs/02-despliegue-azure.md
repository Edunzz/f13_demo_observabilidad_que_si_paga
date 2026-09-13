# 02. Despliegue de infraestructura en Azure

Este documento explica, paso a paso, cómo ejecutar `infra/azure/deploy.sh` `[LOCAL]` para aprovisionar
la VM de laboratorio `f13demo` dentro del resource group **existente** `ace_JoseRomero`. Antes de
continuar, completa `docs/01-prerequisitos.md`.

`deploy.sh` es **idempotente**: puedes volver a ejecutarlo cuantas veces quieras. Si los recursos ya
existen y son compatibles con la configuración esperada, se reutilizan sin duplicarse ni recrearse
(ver la sección "Idempotencia" al final).

## Variables de entorno de `deploy.sh`

Todas admiten override exportándolas antes de correr el script. Ninguna es obligatoria: todas tienen
un valor por defecto razonable para este laboratorio.

| Variable | Default | Descripción |
|---|---|---|
| `RESOURCE_GROUP` | `ace_JoseRomero` | Resource group **existente**. El script nunca lo crea; si no existe, termina en el Paso 2. |
| `VM_NAME` | `f13demo` | Nombre de la VM y hostname configurado por cloud-init. |
| `ADMIN_USER` | `azureuser` | Usuario administrador Linux (autenticación exclusivamente por clave SSH). |
| `VM_SIZE` | `Standard_D4s_v5` | Tamaño de VM deseado. Ver fallback más abajo si no está disponible en la región. |
| `IMAGE` | `Ubuntu2404` | Alias de imagen Ubuntu 24.04 LTS. |
| `VNET_NAME` | `f13demo-vnet` | Nombre de la VNet (`10.13.0.0/16`). |
| `SUBNET_NAME` | `f13demo-subnet` | Nombre de la subnet (`10.13.1.0/24`). |
| `NSG_NAME` | `f13demo-nsg` | Nombre del Network Security Group. |
| `PUBLIC_IP_NAME` | `f13demo-pip` | Nombre de la IP pública (SKU Standard, asignación estática). |
| `NIC_NAME` | `f13demo-nic` | Nombre de la interfaz de red. |
| `OS_DISK_NAME` | `f13demo-osdisk` | Nombre del disco de sistema operativo (Premium_LRS, 64 GB). |
| `SSH_PUBLIC_KEY_PATH` | `$HOME/.ssh/id_ed25519.pub` | Ruta a la clave pública SSH. Si no existe, el script termina; no genera claves ni adivina otra ruta. |
| `AZURE_LOCATION` | (vacío → región del resource group) | Región de Azure a usar. Si se deja vacío, se toma automáticamente de `az group show`. |
| `ADMIN_CIDR` | (vacío → IP pública actual `/32` autodetectada) | CIDR IPv4 admitido en el NSG. Ver cálculo abajo. |
| `AUTO_SHUTDOWN_TIME` | `1900` | Hora de auto-apagado (formato `HHMM`). |
| `AUTO_SHUTDOWN_TIMEZONE` | `America/Bogota` | Zona horaria del auto-apagado. |

Todos los recursos se etiquetan con `project=f13-demo owner=JoseRomero
purpose=observabilidad-que-si-paga environment=demo`, lo que permite auditarlos o limpiarlos por tag
(ver `docs/09-limpieza-costos.md`).

## Ejecución `[LOCAL]`

```bash
# [LOCAL] Ejecución con todos los defaults
bash infra/azure/deploy.sh

# [LOCAL] Ver ayuda completa (todas las variables documentadas en el propio script)
bash infra/azure/deploy.sh --help

# [LOCAL] Ejemplo con override explícito de tamaño de VM y CIDR de acceso
VM_SIZE=Standard_D4as_v5 ADMIN_CIDR=203.0.113.5/32 bash infra/azure/deploy.sh
```

## Orden de creación de recursos

`deploy.sh` ejecuta, en este orden exacto, 14 pasos numerados (cada uno impreso en consola como
`=== Paso N: ... ===`):

1. **Suscripción activa**: `az account show`, se imprime nombre e ID.
2. **Resource group**: valida que `ace_JoseRomero` exista y sea accesible (`az group show`). Si no
   existe, termina con error — este script **nunca** crea el resource group.
3. **Clave SSH y CIDR**: valida que `SSH_PUBLIC_KEY_PATH` exista y tenga formato `ssh-...`; valida o
   calcula `ADMIN_CIDR` (ver siguiente sección).
4. **Disponibilidad de tamaño de VM**: verifica `VM_SIZE` en la región resuelta; si no está
   disponible, prueba la lista de fallback (ver más abajo).
5. **VNet/subnet**: crea (si no existe) `f13demo-vnet` en `10.13.0.0/16` con subnet `f13demo-subnet`
   en `10.13.1.0/24`.
6. **NSG y reglas**: crea (si no existe) `f13demo-nsg` con 4 reglas de entrada, todas con origen
   `$ADMIN_CIDR` y protocolo TCP:

   | Regla | Puerto | Prioridad |
   |---|---|---|
   | `Allow-SSH-Admin` | 22 | 100 |
   | `Allow-App-Admin` | 8080 | 110 |
   | `Allow-Grafana-Admin` | 3000 | 120 |
   | `Allow-Jaeger-Admin` | 16686 | 130 |

   Si el NSG ya existe pero una regla difiere de lo esperado (puerto, prioridad, protocolo o
   dirección), el script se detiene sin sobreescribir nada — solo actualiza automáticamente el
   **origen** de la regla si detecta que cambió la IP pública del operador (ver
   `docs/08-troubleshooting.md`).
7. **IP pública**: crea (si no existe) `f13demo-pip`, SKU Standard, asignación estática.
8. **NIC**: crea (si no existe) `f13demo-nic`, asociada a la subnet y al NSG.
9. **VM**: crea (si no existe) `f13demo`, Ubuntu 24.04 LTS, disco `Premium_LRS` de 64 GB, clave SSH,
   `cloud-init.yaml` como custom-data. Si la VM ya existe, valida que su tamaño y su SKU de imagen
   coincidan con lo esperado antes de reutilizarla; si difieren, se detiene (no la recrea
   automáticamente, para no arriesgar pérdida de datos).
10. **Auto-shutdown**: configura `az vm auto-shutdown` con `AUTO_SHUTDOWN_TIME` /
    `AUTO_SHUTDOWN_TIMEZONE`.
11. **Espera `running`**: sondea `az vm get-instance-view` hasta 300 s (intervalos de 10 s).
12. **Conectividad**: prueba TCP/22 y luego SSH real, con hasta 10 reintentos de 15 s cada uno.
13. **Guardar estado**: escribe `.f13demo-state.env` en la raíz del repo (ignorado por Git, sin
    secretos) con resource group, IP, usuario y nombres de recursos.
14. **Imprimir acceso**: comando SSH y URLs (aplicación, Grafana, Jaeger).

## Cómo se calcula `ADMIN_CIDR`

Si defines `ADMIN_CIDR` explícitamente, el script solo valida que tenga formato CIDR IPv4 correcto
(`x.x.x.x/0-32`) y lo usa tal cual. Si lo dejas vacío (comportamiento por defecto):

1. El script consulta tu IP pública actual contra `https://ifconfig.me`.
2. Si `ifconfig.me` no responde, reintenta contra `https://api.ipify.org`.
3. Si ninguno responde, el script termina con error pidiéndote definir `ADMIN_CIDR` manualmente.
4. Si obtiene una IP válida, arma `ADMIN_CIDR="<tu-ip>/32"` y lo usa para las 4 reglas del NSG.

Salida esperada aproximada:

```text
=== Paso 3: validando clave SSH y CIDR de acceso ===
Clave SSH pública OK: /home/usuario/.ssh/id_ed25519.pub
ADMIN_CIDR no definido, detectando IP pública actual del operador...
IP pública detectada: 203.0.113.5 -> ADMIN_CIDR=203.0.113.5/32
```

Si tu IP pública cambia entre una demo y otra (red distinta, VPN, etc.), simplemente vuelve a correr
`deploy.sh`: el Paso 6 detecta la diferencia y actualiza solo el origen de las reglas del NSG (ver
`docs/08-troubleshooting.md`).

## Si el tamaño de VM por defecto no está disponible

El Paso 4 prueba, en este orden, hasta encontrar el primer tamaño disponible sin restricciones en la
región resuelta:

1. `VM_SIZE` (por defecto `Standard_D4s_v5`)
2. `Standard_D4as_v5`
3. `Standard_D4s_v4`
4. `Standard_D4_v5`
5. `Standard_D4d_v5`

El script **nunca** elige silenciosamente un tamaño más costoso: si tiene que usar un fallback,
imprime explícitamente cuál usó y por qué. Si ninguno de los 5 candidatos está disponible en la
región, termina con error.

Salida esperada aproximada cuando el default no está disponible:

```text
=== Paso 4: verificando disponibilidad de tamaño de VM en 'eastus' ===
Verificando 'Standard_D4s_v5'...
Aviso: 'Standard_D4s_v5' no está disponible (o tiene restricciones) en 'eastus'.
Se usará 'Standard_D4as_v5' en su lugar: primer tamaño equivalente disponible de la lista de fallback.
Tamaño de VM a usar: Standard_D4as_v5
```

## Verificar el resultado con `status.sh`

```bash
# [LOCAL]
bash infra/azure/status.sh
```

`status.sh` muestra: estado de la VM en Azure (`az vm show`), power state, IP pública actual, reglas
del NSG y el comando SSH listo para copiar. Es de solo lectura: no modifica nada.

Salida esperada aproximada:

```text
=== VM 'f13demo' (resource group 'ace_JoseRomero') ===
Name     ResourceGroup    Location    ...
f13demo  ace_JoseRomero   eastus      ...

=== Power state ===
Estado: VM running

=== IP pública actual ('f13demo-pip') ===
IP pública: 203.0.113.10

=== Comando SSH ===
ssh azureuser@203.0.113.10
```

## Idempotencia

Ejecutar `deploy.sh` una segunda vez (por ejemplo, después de que cambió tu IP pública, o solo para
confirmar el estado) **no duplica ni recrea recursos**:

- Cada recurso se verifica primero con `az ... show` antes de crearse; si ya existe, se reutiliza.
- Si un recurso existente tiene una configuración incompatible con la esperada (tamaño de VM
  distinto, reglas de NSG distintas), el script se detiene con un mensaje explicando la diferencia,
  en vez de sobrescribir silenciosamente.
- La única actualización automática permitida sobre un recurso preexistente es el origen de las
  reglas del NSG, cuando `ADMIN_CIDR` cambió respecto al último despliegue.

## Referencias

- Azure CLI — `az vm`: https://learn.microsoft.com/en-us/cli/azure/vm
- Azure CLI — `az network nsg`: https://learn.microsoft.com/en-us/cli/azure/network/nsg
- Azure — grupos de seguridad de red (NSG): https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview
- Azure CLI — referencia general: https://learn.microsoft.com/en-us/cli/azure/
