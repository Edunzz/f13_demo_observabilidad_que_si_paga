# 09. Costos y limpieza

El laboratorio F13 no crea recursos en ninguna nube: todo vive dentro de tu GitHub Codespace. El único
costo es el uso de Codespaces (horas de cómputo y GB de almacenamiento), que en una cuenta personal sale
de la cuota mensual gratuita mientras no la superes.

## Qué consume cuota

| Estado del Codespace | Cómputo | Almacenamiento |
|---|---|---|
| **Activo** (abierto, o corriendo el stack) | Sí, por hora y por núcleo | Sí |
| **Detenido** (Stop o por inactividad) | No | Sí, mientras exista |
| **Borrado** | No | No |

El tamaño de máquina multiplica el consumo de cómputo: una máquina de 4 núcleos consume el doble de
horas-núcleo que una de 2. El laboratorio funciona con la de 2 núcleos (ver `docs/01-prerequisitos.md`).

Consulta la cuota incluida y los precios vigentes en la documentación oficial (ver Referencias): no
inventes ni repitas cifras de memoria en presentaciones o documentación.

## Detener vs. borrar

| Acción | Cómo | Qué conservas |
|---|---|---|
| **Detener el stack** (sin cerrar el Codespace) | `docker compose down` | Imágenes y volúmenes; `bash scripts/lab-up.sh` lo levanta de nuevo |
| **Borrar datos del stack** | `docker compose down -v` (o `make clean`) | Nada de métricas, trazas ni estado de Grafana |
| **Detener el Codespace** | github.com/codespaces → ⋯ → *Stop codespace*, o paleta de comandos → **Codespaces: Stop Current Codespace**; también se detiene solo tras el tiempo de inactividad | Todo: al reabrirlo, `lab-up.sh` levanta el stack |
| **Borrar el Codespace** | github.com/codespaces → ⋯ → *Delete* | Nada (tu `.env` y los datos se pierden; el repo sigue en GitHub) |

Con GitHub CLI desde tu máquina:

```bash
gh codespace list
gh codespace stop -c <nombre>
gh codespace delete -c <nombre>
```

**Regla simple: si no vas a usar el laboratorio en las próximas horas, detén el Codespace. Si ya
terminaste con él, bórralo.**

## Ver tu consumo real

- github.com → **Settings → Billing and plans** (o *Billing and licensing*) → uso de Codespaces.
- Los Codespaces inactivos se detienen solos tras el *idle timeout* (configurable en Settings →
  Codespaces) y GitHub borra automáticamente los detenidos tras el período de retención configurado.

## Referencias

- Facturación de Codespaces: https://docs.github.com/billing/managing-billing-for-your-products/managing-billing-for-github-codespaces/about-billing-for-github-codespaces
- Detener y borrar un Codespace: https://docs.github.com/codespaces/developing-in-a-codespace/stopping-and-starting-a-codespace · https://docs.github.com/codespaces/developing-in-a-codespace/deleting-a-codespace
- Tiempo de inactividad y retención: https://docs.github.com/codespaces/setting-your-user-preferences/setting-your-timeout-period-for-github-codespaces · https://docs.github.com/codespaces/setting-your-user-preferences/configuring-automatic-deletion-of-your-codespaces
- `gh codespace`: https://cli.github.com/manual/gh_codespace
