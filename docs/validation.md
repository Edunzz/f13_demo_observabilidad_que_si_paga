# Validación - criterios de aceptación y evidencia

Este documento define qué significa que el laboratorio F13 "funciona" en GitHub Codespaces y dónde
queda la evidencia. No contiene secretos ni datos sensibles.

## Cómo se valida

Cada push a `main` (y cada pull request) ejecuta
[`.github/workflows/validate.yml`](../.github/workflows/validate.yml), sin credenciales externas:

| Job | Qué valida |
|---|---|
| ShellCheck | Todos los scripts de `scripts/` (con `-x -P SCRIPTDIR`) |
| YAML lint | `compose.yaml`, configuración de Collector/Prometheus/Grafana y el propio workflow |
| Pruebas Python (×4) | `pytest` de `shop-api`, `payment-service`, `value-exporter` y `load-generator` |
| JSON | Dashboards de Grafana y `.devcontainer/devcontainer.json` |
| Diagrama Draw.io | `docs/architecture.drawio` es XML válido y existe el PNG exportado |
| gitleaks | Ningún secreto en el historial |
| **Stack E2E** | `scripts/lab-up.sh` (el mismo `postStartCommand` del Codespace) → `business-snapshot.sh` → `inject-fault.sh --yes` → espera a que `f13_business_revenue_at_risk_usd_per_minute > 0` → `recover.sh` → `demo-reset.sh` |
| **Devcontainer de Codespaces** | Construye `.devcontainer/` con `devcontainers/ci` (Docker-in-Docker, igual que un Codespace) y, dentro, corre `lab-up.sh`, `status.sh`, `inject-fault.sh`, `recover.sh` y `business-snapshot.sh` |

El resultado de cada ejecución está en la pestaña
[Actions](https://github.com/Edunzz/f13_demo_observabilidad_que_si_paga/actions/workflows/validate.yml)
del repositorio.

## Criterios de aceptación

| # | Criterio | Cómo se comprueba |
|---|---|---|
| 1 | El devcontainer se construye con Docker-in-Docker y Compose v2 | Job *Devcontainer de Codespaces* |
| 2 | `lab-up.sh` deja los 8 servicios `healthy` (o sin healthcheck por diseño: `load-generator`, `otel-collector`) en menos de 5 minutos | `wait_for_healthy` en `lab-up.sh` (ambos jobs E2E) |
| 3 | `POST /checkout` responde 200 con `"outcome"` en estado sano | `smoke-test.sh`, paso 2 |
| 4 | Prometheus tiene todas las métricas `f13_*` requeridas | `smoke-test.sh`, paso 3 |
| 5 | Grafana tiene provisionados `f13-tecnico` y `f13-impacto-negocio` | `smoke-test.sh`, paso 5 |
| 6 | Jaeger recibe trazas de `shop-api` y `payment-service` | `smoke-test.sh`, paso 7 |
| 7 | `inject-fault.sh` activa la falla (`f13_fault_active=1`) y el ingreso en riesgo sube por encima de 0 en menos de 2 minutos | Job *Stack E2E*, paso "Verificar que el ingreso en riesgo sube" |
| 8 | `recover.sh` devuelve `f13_fault_active` a 0 sin reiniciar el stack | `recover.sh` (ambos jobs E2E) |
| 9 | `demo-reset.sh` deja el entorno listo para repetir (acumulador en 0 + smoke test verde) | Job *Stack E2E* |
| 10 | Las APIs admin (`8001`, `9200`) escuchan solo en `127.0.0.1` y no se reenvían | `compose.yaml` (`127.0.0.1:` en `ports`) + `otherPortsAttributes: ignore` en `devcontainer.json` |
| 11 | Ningún secreto en Git; `.env` se genera en el Codespace | gitleaks + `.gitignore` + `setup-env.sh` |
| 12 | Un Codespace nuevo queda listo siguiendo solo el `README.md` | Los jobs E2E ejecutan exactamente los scripts que el README indica |

Lo que el CI **no** puede comprobar, porque depende de la cuenta de GitHub de quien abre el Codespace:
que `gh codespace ports visibility` cambie los puertos a Public (las organizaciones pueden prohibirlo) y
la apariencia de las URLs `*.app.github.dev`. `publish-ports.sh` avisa y deja los puertos privados si
no puede publicarlos.

## Validación manual en un Codespace

```bash
bash scripts/status.sh            # 8 contenedores, falla inactiva, URLs
bash scripts/smoke-test.sh        # 7/7 verificaciones
bash scripts/inject-fault.sh --yes
bash scripts/business-snapshot.sh # tras ~60 s: falla SI, error ~30 %, ingreso en riesgo > 0
bash scripts/demo-reset.sh        # recover + acumulador en 0 + smoke test
```

## Historial

- **2026-09-13** - validación end-to-end sobre una VM de Azure (despliegue con `infra/azure/` y
  orquestación por SSH), commit `64c9708`. Esa ruta de despliegue se retiró al pasar el laboratorio a
  GitHub Codespaces; el detalle sigue disponible en el historial de Git (`git show 2b812c2:docs/validation.md`).
- **2026-10-06** - el laboratorio pasa a levantarse completo en GitHub Codespaces (devcontainer con
  Docker-in-Docker, scripts locales sin SSH, puertos web publicados en HTTP). La validación queda a cargo
  de los jobs *Stack E2E* y *Devcontainer de Codespaces* del workflow `validate`.
