# 01. Prerrequisitos

Este documento lista todo lo que necesitas **antes** de ejecutar cualquier script del laboratorio F13
(`https://github.com/Edunzz/f13_demo_observabilidad_que_si_paga`). Todos los pasos de esta página se
ejecutan en tu máquina de operador, es decir `[LOCAL]`.

> Nota: todos los valores de negocio del laboratorio (ingresos, tickets, tasas de conversión) son
> **ilustrativos**. Sirven para demostrar el método, no representan datos de ninguna organización real.

## 1. Cuenta y suscripción de Azure

- Necesitas una suscripción de Azure activa.
- Necesitas acceso al **resource group ya existente** `ace_JoseRomero`. Ningún script de este
  laboratorio crea el resource group: si no existe o no tienes acceso a él, `infra/azure/deploy.sh`
  termina con error explícito en el Paso 2.
- No necesitas permisos a nivel de suscripción; basta con permisos sobre ese resource group (ver
  sección de permisos IAM más abajo).

## 2. Azure CLI instalado y autenticado

- Instala Azure CLI siguiendo la documentación oficial `{ref instalación Azure CLI https://learn.microsoft.com/en-us/cli/azure/install-azure-cli}`.
- Autentícate:

  ```bash
  # [LOCAL]
  az login
  ```

- Si tienes acceso a más de una suscripción, selecciona la correcta:

  ```bash
  # [LOCAL]
  az account set --subscription "<nombre-o-id-de-la-suscripcion>"
  ```

## 3. Clave SSH ya generada

`infra/azure/deploy.sh` **no genera claves SSH nuevas**; solo valida que exista una clave pública en
la ruta esperada (por defecto `$HOME/.ssh/id_ed25519.pub`) y falla con un mensaje claro si no la
encuentra. Genera una clave `ed25519` (recomendada) o `RSA` antes de continuar:

```bash
# [LOCAL]
ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519"
```

Si usas otra ruta o un par de claves existente, exporta `SSH_PUBLIC_KEY_PATH` apuntando a tu clave
pública antes de correr `deploy.sh` (ver `docs/02-despliegue-azure.md`). Referencia oficial sobre
claves SSH para VMs Linux en Azure: `{ref generación de claves SSH https://learn.microsoft.com/en-us/azure/virtual-machines/linux/mac-create-ssh-keys}`.

## 4. Git y una cuenta de GitHub

- Git instalado localmente (para clonar el repo del laboratorio en tu propia máquina, si aún no lo
  tienes, y opcionalmente para hacer fork).
- Una cuenta de GitHub con acceso de lectura al repositorio
  `https://github.com/Edunzz/f13_demo_observabilidad_que_si_paga` (o a tu propio fork). El acceso de
  lectura es el único requisito para seguir esta documentación: `scripts/remote-install.sh` clona el
  repositorio **dentro de la VM** (no localmente) usando la URL pública HTTPS.

## 5. Docker y Docker Compose: NO son necesarios en tu máquina

Este es un punto importante: **no necesitas instalar Docker ni Docker Compose en la máquina del
operador**. Todo el stack de contenedores corre exclusivamente dentro de la VM `f13demo`, donde:

- `infra/azure/cloud-init.yaml` instala Docker Engine y el plugin Docker Compose en el primer
  arranque de la VM (ver `{ref instalación de Docker Engine en Ubuntu https://docs.docker.com/engine/install/ubuntu/}`).
- `scripts/remote-install.sh` ejecuta `docker compose build` / `up -d` **por SSH, dentro de la VM**.

Tu máquina de operador solo necesita `az`, `ssh`, `curl` y `git` (todos verificados automáticamente
por los scripts antes de continuar; si falta alguno, el script termina con un mensaje claro en vez de
fallar a medias).

## 6. Permisos IAM mínimos en el resource group

`infra/azure/deploy.sh` crea, dentro de `ace_JoseRomero`, los siguientes tipos de recurso: VNet/subnet,
NSG y reglas, IP pública, NIC, VM (con disco administrado) y una configuración de auto-shutdown. Para
poder ejecutar todas esas operaciones necesitas, como mínimo, uno de los siguientes conjuntos de rol
asignados sobre el resource group `ace_JoseRomero` (no sobre toda la suscripción), según el catálogo
oficial de roles integrados de Azure RBAC `{ref Azure built-in roles https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles}`:

| Opción | Rol(es) | Cuándo usarla |
|---|---|---|
| Simple | **Contributor** sobre el resource group `ace_JoseRomero` | Recomendada para el laboratorio: cubre red, cómputo y auto-shutdown sin fricción. |
| Con menor privilegio | **Virtual Machine Contributor** + **Network Contributor** sobre `ace_JoseRomero` | Si tu organización exige roles acotados en vez de Contributor genérico. Cubre VM/disco/auto-shutdown y VNet/NSG/IP pública/NIC respectivamente. |

Si tu rol es más restrictivo que estas dos opciones, `deploy.sh` fallará en el paso correspondiente
(por ejemplo, al crear el NSG o la VM) con el error que devuelva Azure CLI; en ese caso, pide al
propietario del resource group que te asigne uno de los roles de la tabla.

## 7. Verificaciones previas recomendadas

Antes de ejecutar `infra/azure/deploy.sh`, confirma lo siguiente:

```bash
# [LOCAL] Confirma la suscripción activa
az account show

# [LOCAL] Confirma que el resource group existe y es accesible
az group show --name ace_JoseRomero
```

Salida esperada aproximada de `az group show`:

```json
{
  "id": "/subscriptions/<sub-id>/resourceGroups/ace_JoseRomero",
  "location": "eastus",
  "name": "ace_JoseRomero",
  "properties": { "provisioningState": "Succeeded" },
  "tags": null
}
```

Si alguno de estos dos comandos falla, resuélvelo (login, cambio de suscripción, o solicitud de
acceso) antes de continuar con `docs/02-despliegue-azure.md`.

## Checklist rápido

- [ ] `az account show` funciona y muestra la suscripción correcta.
- [ ] `az group show --name ace_JoseRomero` funciona (el resource group existe y es accesible).
- [ ] Tengo una clave SSH pública en `~/.ssh/id_ed25519.pub` (o conozco la ruta de una existente).
- [ ] Tengo Git instalado y acceso de lectura al repositorio del laboratorio en GitHub.
- [ ] Confirmo que **no** necesito instalar Docker/Compose localmente.
- [ ] Tengo asignado Contributor (o el par Virtual Machine Contributor + Network Contributor) sobre `ace_JoseRomero`.

## Referencias

- Azure CLI — instalación: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
- Azure CLI — referencia de comandos: https://learn.microsoft.com/en-us/cli/azure/
- Generación de claves SSH para VMs Linux en Azure: https://learn.microsoft.com/en-us/azure/virtual-machines/linux/mac-create-ssh-keys
- Azure RBAC — roles integrados: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles
- Docker Engine — instalación en Ubuntu: https://docs.docker.com/engine/install/ubuntu/
- Docker Compose: https://docs.docker.com/compose/
