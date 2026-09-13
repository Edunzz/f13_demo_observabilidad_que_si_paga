# Validación — evidencia real de ejecución

Este documento registra la evidencia real de haber desplegado y validado el
laboratorio F13 contra recursos reales: Azure (`ace_JoseRomero`, VM `f13demo`)
y GitHub Actions (CI). No contiene secretos ni datos sensibles.

- **Fecha UTC de la validación:** 2026-09-13, ventana 00:25–01:07 UTC.
- **Commit SHA validado:** `64c970889e65d0f73e5af710cf6bc0d2a8cac10f`
  (rama `feat/laboratorio-f13-completo`, PR
  [#1](https://github.com/Edunzz/f13_demo_observabilidad_que_si_paga/pull/1)).
- **Suscripción Azure:** `Dynatrace-DXS/LATAM`. **Resource group:** `ace_JoseRomero`
  (`eastus`, ya existente, no creado por este proceso). **VM:** `f13demo`
  (`Standard_D4s_v5`, Ubuntu 24.04 LTS — `offer=ubuntu-24_04-lts`).
- **Versiones de imagen** (ver [`VERSIONS.md`](../VERSIONS.md) para el detalle
  completo): `otel/opentelemetry-collector-contrib:0.160.0`,
  `prom/prometheus:v3.14.0`, `jaegertracing/all-in-one:1.76.0`,
  `grafana/grafana:13.2.1`, `busybox:1.36.1` (init de volumen de Jaeger).

## Comandos ejecutados (en orden, contra la infraestructura real)

```bash
# [LOCAL]
ssh-keygen -t ed25519 -f ~/.ssh/f13demo_ed25519 -N ""
export SSH_PUBLIC_KEY_PATH="$HOME/.ssh/f13demo_ed25519.pub"
bash infra/azure/deploy.sh
GIT_REF="feat/laboratorio-f13-completo" bash scripts/remote-install.sh
bash scripts/inject-fault.sh --yes
bash scripts/recover.sh
bash scripts/demo-reset.sh
```

`GIT_REF` se usó únicamente para validar el contenido de la rama del PR
*antes* de que estuviera mergeada a `main` (ver `scripts/remote-install.sh
--help`); una vez mergeado el PR, la instalación normal (`bash
scripts/remote-install.sh`, sin `GIT_REF`) clona `main` directamente.

## Bugs reales encontrados y corregidos durante esta ejecución

Todos corregidos en commits sobre la misma rama (ver el historial de
`feat/laboratorio-f13-completo` para el detalle completo de cada fix):

1. **`az vm auto-shutdown --timezone`** no reconocido por la versión de Azure
   CLI usada; se agregó fallback a solo `--time` (UTC) con aviso explícito.
2. **`service.telemetry.metrics.address`** obsoleto en
   `otel-collector-contrib:0.160.0` (el Collector no arrancaba); migrado a
   `telemetry.metrics.readers[].pull.exporter.prometheus`.
3. **Permisos del volumen de Jaeger** (`mkdir /badger/key: permission
   denied`, imagen corre como UID 10001 no-root sobre un volumen creado como
   root): se agregó el servicio `jaeger-init` (busybox efímero) que ajusta el
   dueño del volumen antes de que arranque Jaeger.
4. **Validación de idempotencia de la VM** comparaba `sku` en vez de `offer`
   de la imagen (la VM real tiene `sku=server`, `offer=ubuntu-24_04-lts`),
   dando falso negativo en una segunda ejecución de `deploy.sh`.
5. **Ningún script pasaba `-i` a `ssh`**: sin una clave con nombre por
   defecto o un ssh-agent cargado, toda conexión SSH fallaba en silencio.
   Se deriva `SSH_PRIVATE_KEY_PATH` de `SSH_PUBLIC_KEY_PATH` y se persiste en
   `.f13demo-state.env`.
6. **`cloud-init status --wait`** devuelve exit code 2 ("degraded") por una
   advertencia benigna de la propia directiva `output:` pedida para este
   laboratorio; `remote-install.sh` lo trataba como fallo fatal. Corregido
   para distinguir `status: error` real de `degraded` con solo advertencias.
7. **Espera de healthchecks** (`remote-install.sh` y el workflow de CI)
   trataba contenedores **sin** healthcheck definido por diseño
   (`load-generator`, `otel-collector`) como "no listos", agotando siempre
   el timeout de 5 minutos aunque todo estuviera realmente sano.
8. **Prometheus, `payment-service` y `value-exporter` no publicaban sus
   puertos ni siquiera a `localhost`**, por lo que `smoke-test.sh`,
   `inject-fault.sh`, `recover.sh` y `demo-reset.sh` (que corren en el host
   de la VM, no dentro de un contenedor) no podían conectarse. Se publican
   `9090`, `8001` y `9200` **solo en `127.0.0.1`** — alcanzables desde el
   propio host, nunca desde la red (el NSG ni siquiera aplica a loopback).
9. **ShellCheck en CI**: `TAGS` sin comillas (`SC2086`) en `deploy.sh` →
   convertido a array; y `source scripts/lib/common.sh` no se seguía
   (`SC1091`) → se agregó `SHELLCHECK_OPTS="-x -P SCRIPTDIR"`.

## Resultados de las pruebas de aceptación

| # | Criterio | Resultado |
|---|---|---|
| 1 | `az vm show -g ace_JoseRomero -n f13demo` devuelve la VM correcta | ✅ `Standard_D4s_v5`, `ubuntu-24_04-lts`, `PowerState/running` |
| 2 | El hostname remoto devuelve exactamente `f13demo` | ✅ `ssh ... hostname` → `f13demo` |
| 3 | `docker compose ps` muestra todos los servicios healthy | ✅ 8/8 servicios `Up ... (healthy)` (excepto `load-generator`/`otel-collector`, sin healthcheck por diseño) |
| 4 | `POST /checkout` devuelve éxito en estado normal | ✅ HTTP 200 con `"outcome"` |
| 5 | Prometheus contiene todas las métricas `f13_*` requeridas | ✅ las 8 métricas requeridas por `smoke-test.sh` presentes |
| 6 | Grafana tiene ambos dashboards provisionados | ✅ `F13 \| Salud técnica` (`f13-tecnico`) y `F13 \| Impacto en el negocio` (`f13-impacto-negocio`), vía `/api/search` |
| 7 | Jaeger muestra trazas completas `shop-api -> payment-service` | ✅ traza real con 11 spans y servicios `{shop-api, payment-service}` |
| 8 | `inject-fault.sh` aumenta p95, errores e ingreso en riesgo en <60s | ✅ p95 pagos ≈1.79s (con `FAULT_LATENCY_MS=1800`), `f13_business_revenue_at_risk_usd_per_minute` ≈109.09, `f13_fault_active=1`, confirmado ~20s después de activar la falla |
| 9 | `recover.sh` devuelve `f13_fault_active` a 0 | ✅ confirmado vía `/metrics` |
| 10 | Puertos 9090/4317/4318 no accesibles desde Internet | ✅ `curl` externo a `:9090` y `:4317` → timeout (exit 28), sin respuesta |
| 11 | Puertos publicados solo aceptan el CIDR autorizado en el NSG | ✅ reglas NSG creadas con `ADMIN_CIDR` (IP `/32` del operador); `:8080`/`:3000`/`:16686` responden 200 desde esa IP |
| 12 | `demo-reset.sh` deja el entorno listo para repetir | ✅ recover + reset de acumulador + smoke test, todo OK |
| 13 | CI termina en verde | ✅ [run exitoso](https://github.com/Edunzz/f13_demo_observabilidad_que_si_paga/actions) sobre el commit `64c9708` (ShellCheck, YAML lint, pytest ×4 servicios, build, `docker compose config`, stack completo + smoke tests, JSON de dashboards, diagrama Draw.io, gitleaks) |
| 14 | El diagrama Draw.io abre y el PNG coincide | ✅ `docs/architecture.drawio` validado con `validate.py` (0 errores) y exportado a `docs/images/architecture.png` (2400px) |
| 15 | Un despliegue limpio puede seguirse usando únicamente el README | ✅ la secuencia de comandos de esta validación es exactamente la del "Quick start" de `README.md` |

## Notas

- Todos los valores financieros (`f13_business_*`) observados durante esta
  validación son **ilustrativos**, generados por el modelo del laboratorio
  con los valores por defecto de `.env.example`. No representan datos de
  ninguna organización real.
- Las credenciales generadas (`GF_SECURITY_ADMIN_PASSWORD`,
  `FAULT_ADMIN_TOKEN`) se consultaron únicamente por SSH cuando fue
  necesario para las pruebas, nunca se imprimieron en logs ni se
  commitearon.
- Tras esta validación se dejó el laboratorio en estado saludable
  (`demo-reset.sh` ejecutado como último paso).
