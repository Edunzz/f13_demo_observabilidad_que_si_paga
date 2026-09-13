# 09. Limpieza y control de costos

Este documento explica cómo detener el laboratorio F13 sin perder recursos, cómo destruirlo por
completo si ya no lo necesitas, y cómo consultar el costo real en Azure sin inventar cifras.

## Parar vs. destruir

| Acción | Comando | Qué hace | Qué NO hace |
|---|---|---|---|
| **Parar** (recomendado entre demos o al final del día) | `bash infra/azure/stop.sh` `[LOCAL]` | Ejecuta `az vm deallocate` sobre `f13demo`: libera el hardware asignado y **detiene la facturación de cómputo**. Pide confirmación escrita salvo que uses `--yes`. | No borra la VM, sus discos, su IP pública, ni ningún otro recurso — todo queda intacto para volver a encenderlo. |
| **Encender de nuevo** | `bash infra/azure/start.sh` `[LOCAL]` | `az vm start`, espera estado `running` y valida conectividad TCP/SSH con reintentos. | No reinstala ni reconfigura nada; el stack de contenedores debería seguir donde quedó (revisa con `docker compose ps` `[VM f13demo]`, y si hace falta, vuelve a correr `docker compose up -d` `[VM f13demo]`). |
| **Destruir recursos del laboratorio** (cuando ya no lo vas a usar más) | `bash infra/azure/destroy-lab-resources.sh` `[LOCAL]` | Borra, uno por uno y por nombre exacto con prefijo `f13demo`: VM, NIC, disco OS, IP pública, NSG y VNet. Exige escribir literalmente `f13demo` para confirmar, salvo `--yes`. | **Nunca borra el resource group `ace_JoseRomero`** (el script ni siquiera tiene la capacidad de ejecutar `az group delete`) — recursos ajenos al laboratorio que compartan ese resource group quedan intactos. |

```bash
# [LOCAL] Parar (detener facturación de cómputo) sin destruir nada
bash infra/azure/stop.sh

# [LOCAL] Parar sin confirmación interactiva (por ejemplo, al final de un script de CI)
bash infra/azure/stop.sh --yes

# [LOCAL] Volver a encender para la siguiente sesión/demo
bash infra/azure/start.sh

# [LOCAL] Destruir completamente los recursos del laboratorio (mantiene el RG)
bash infra/azure/destroy-lab-resources.sh
```

Salida esperada aproximada de `destroy-lab-resources.sh` (fragmento):

```text
==================================================================
Se van a borrar estos recursos del resource group 'ace_JoseRomero':
  1. VM:          f13demo
  2. NIC:         f13demo-nic
  3. Disco OS:    f13demo-osdisk
  4. IP pública:  f13demo-pip
  5. NSG:         f13demo-nsg
  6. VNet:        f13demo-vnet

El resource group 'ace_JoseRomero' NO se borra (este script nunca ejecuta 'az group delete').
==================================================================
Escribe literalmente 'f13demo' para confirmar el borrado:
```

## Verificar que no queden recursos huérfanos

Todos los recursos del laboratorio se etiquetan, en su creación, con
`project=f13-demo owner=JoseRomero purpose=observabilidad-que-si-paga environment=demo`. Después de
correr `destroy-lab-resources.sh`, confirma que no quedó nada suelto con ese tag dentro del resource
group:

```bash
# [LOCAL]
az resource list --resource-group ace_JoseRomero --tag project=f13-demo -o table
```

Salida esperada aproximada tras una limpieza completa:

```text
Name    ResourceGroup    Location    Type
------  ---------------  ----------  ------
```

(una tabla vacía, sin filas). Si aparece algún recurso, revisa su nombre: `destroy-lab-resources.sh`
solo borra recursos cuyo nombre tenga el prefijo `f13demo*`; cualquier recurso con el tag pero nombre
distinto tendría que revisarse y borrarse manualmente con `az resource delete` (o investigarse, ya que
no debería haberse creado con nombre distinto por ninguno de los scripts de este laboratorio).

## Consultar el costo real sin inventar cifras

Este laboratorio **no incluye ningún número de costo estimado**, porque el precio de cómputo de Azure
varía por región, tipo de acuerdo comercial y cambios de catálogo. Para conocer el costo real:

- **Calculadora oficial de precios de Azure** (para estimar antes de desplegar, eligiendo tu región y
  el tamaño de VM real que se haya resuelto en tu despliegue — ver `docs/02-despliegue-azure.md` sobre
  el fallback de tamaños): https://azure.microsoft.com/en-us/pricing/calculator/
- **Tamaños de VM disponibles y sus specs** en tu región (no incluye precio, pero confirma el tamaño
  exacto resuelto por `deploy.sh`):

  ```bash
  # [LOCAL]
  az vm list-sizes --location eastus -o table
  ```

- **Costo acumulado real de la suscripción**, si tienes acceso de facturación (`Cost Management`),
  vía Azure CLI:

  ```bash
  # [LOCAL] (requiere permisos de Cost Management/Billing sobre la suscripción)
  az consumption usage list --output table
  ```

  Si no tienes esos permisos, consulta directamente con quien administre la suscripción, o revisa
  **Cost Management + Billing** en el portal de Azure.

No inventes ni repitas cifras de costo por hora en presentaciones o documentación: siempre remite a
estas dos fuentes (calculadora oficial o el propio Cost Management de la suscripción).

## Recordatorio de costo variable

- La VM `f13demo` usa por defecto el tamaño `Standard_D4s_v5` (con fallback documentado a
  `Standard_D4as_v5`, `Standard_D4s_v4`, `Standard_D4_v5` o `Standard_D4d_v5`; ver
  `docs/02-despliegue-azure.md`). El costo por hora de cómputo **varía según la región** y el tamaño
  efectivamente resuelto — consúltalo siempre con la calculadora oficial antes de asumir un número.
- Mientras la VM esté en estado `running`, se factura cómputo **por hora**, sin importar si estás
  usando la demo en ese momento o no.
- `infra/azure/deploy.sh` configura auto-shutdown (por defecto a las `19:00` hora
  `America/Bogota`) como red de seguridad, pero **no sustituye** desalojar la VM explícitamente
  cuando termines una sesión de trabajo o de ensayo.
- El disco administrado (`Premium_LRS`, 64 GB) y la IP pública Standard siguen facturándose aunque la
  VM esté desasignada (`deallocated`); solo se dejan de facturar por completo al ejecutar
  `destroy-lab-resources.sh`.

**Regla simple: si no vas a usar el laboratorio en las próximas horas, corre `bash
infra/azure/stop.sh` `[LOCAL]`. Si ya terminaste con él por completo, corre `bash
infra/azure/destroy-lab-resources.sh` `[LOCAL]`.**

## Referencias

- Azure CLI — `az vm deallocate` / `az vm start`: https://learn.microsoft.com/en-us/cli/azure/vm
- Azure — calculadora de precios oficial: https://azure.microsoft.com/en-us/pricing/calculator/
- Azure CLI — `az vm list-sizes`: https://learn.microsoft.com/en-us/cli/azure/vm#az-vm-list-sizes
- Azure CLI — `az consumption`: https://learn.microsoft.com/en-us/cli/azure/consumption
- Azure — Cost Management + Billing: https://learn.microsoft.com/en-us/azure/cost-management-billing/
