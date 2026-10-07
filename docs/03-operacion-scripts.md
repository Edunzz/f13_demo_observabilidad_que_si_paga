# 03. Operación: scripts, `.env` y credenciales

Todos los scripts viven en `scripts/`, se ejecutan en la terminal del Codespace desde la raíz del
repo, tienen `-h/--help` y comparten la librería `scripts/lib/common.sh` (logging, lectura de `.env`
sin imprimir secretos, espera de Docker y healthchecks, URLs de Codespaces). Corren contra los puertos
publicados en `localhost`; no usan SSH ni infraestructura remota.

## Scripts

| Script | Qué hace | Modifica algo |
|---|---|---|
| `setup-env.sh` | Crea/completa `.env`, genera secretos, ajusta `GF_SERVER_ROOT_URL` en Codespaces | `.env` |
| `lab-up.sh [--no-smoke]` | `setup-env.sh` → espera Docker → `compose config` → `compose up -d --build` → healthchecks (5 min) → `smoke-test.sh` → `publish-ports.sh` → URLs | Contenedores |
| `status.sh` | `docker compose ps`, estado de la falla y URLs | No |
| `show-urls.sh` | URLs del laboratorio y cómo obtener la contraseña de Grafana | No |
| `smoke-test.sh` | 7 verificaciones: health, checkout, métricas `f13_*`, Grafana, dashboards, Jaeger UI y trazas | Genera 1 checkout |
| `business-snapshot.sh` | Señales técnicas, SLO y capa de valor, leídas de Prometheus | No |
| `inject-fault.sh [ms] [rate] [--yes]` | Activa latencia + errores en `payment-service` (default 1800 ms / 0.30) | Estado de la falla |
| `recover.sh` | Desactiva la falla sin reiniciar nada | Estado de la falla |
| `demo-reset.sh` | `recover.sh` + reset del acumulador financiero + `smoke-test.sh` | Falla y acumulador |
| `publish-ports.sh [--private]` | Visibilidad Public/Private de los puertos web del Codespace | Port forwarding |
| `collect-diagnostics.sh` | Empaqueta ps, logs, config sanitizada, disco/memoria y health endpoints en `diagnostics/` | Crea un `.tar.gz` |

Variable de entorno común: `TARGET_HOST` (default `localhost`), por si quieres apuntar los scripts a
otro host con el mismo stack.

### Smoke test

```bash
bash scripts/smoke-test.sh
```

Salida esperada (aproximada):

```text
[INFO ] Ejecutando smoke test contra TARGET_HOST=localhost
[INFO ] OK: shop-api /health -> 200
[INFO ] OK: shop-api /checkout -> 200 con campo "outcome"
[INFO ] OK: todas las métricas f13_* requeridas están presentes en Prometheus.
[INFO ] OK: Grafana /api/health respondió correctamente.
[INFO ] OK: dashboards f13-tecnico f13-impacto-negocio provisionados.
[INFO ] OK: Jaeger UI -> 200
[INFO ] OK: Jaeger tiene trazas de shop-api payment-service.
[INFO ] Smoke test completo: todas las verificaciones pasaron.
```

Si una falla está activa, el paso 2 puede fallar con HTTP 502 (es el 30% de errores inyectado):
corre `bash scripts/recover.sh` y repite.

## Variables de `.env`

| Variable | Default | Efecto |
|---|---|---|
| `REQUESTS_PER_MINUTE` | `120` | Ritmo objetivo de `load-generator` |
| `AVERAGE_REQUEST_VALUE_USD` | `50` | Valor medio por checkout en la fórmula de ingreso en riesgo |
| `BASELINE_CONVERSION_RATE` | `0.15` | Referencia narrativa (no entra en las fórmulas) |
| `BASELINE_ABANDONMENT_RATE` | `0.10` | Abandono en estado sano |
| `DEGRADED_ABANDONMENT_RATE` | `0.35` | Abandono con la falla activa |
| `AVERAGE_TICKET_USD` | `50` | Ticket medio en la fórmula de pérdida por degradación |
| `SLO_TARGET_RATIO` | `0.999` | SLO objetivo |
| `FAULT_LATENCY_MS` / `FAULT_ERROR_RATE` | `1800` / `0.30` | Valores iniciales de la falla (los argumentos de `inject-fault.sh` los sobrescriben) |
| `GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD` | `admin` / generado | Usuario admin de Grafana |
| `GF_AUTH_ANONYMOUS_ENABLED` / `GF_AUTH_ANONYMOUS_ORG_ROLE` | `true` / `Editor` | Acceso anónimo a Grafana (dashboards + Explore) |
| `GF_SERVER_ROOT_URL` | `http://localhost:3000/` | En Codespaces, `setup-env.sh` la ajusta a la URL del puerto 3000 |
| `FAULT_ADMIN_TOKEN` | generado | Token del header `X-Fault-Admin-Token` de `/admin/fault` |
| `SERVICE_VERSION`, `DEPLOYMENT_ENVIRONMENT`, `OTEL_EXPORTER_OTLP_ENDPOINT` | `0.1.0`, `demo`, `http://otel-collector:4317` | Atributos y destino OpenTelemetry |

Tras editar `.env`, aplica con `docker compose up -d` (recrea solo los servicios cuya configuración
cambió). La contraseña de Grafana solo se aplica cuando su volumen se crea por primera vez; para
cambiarla después, usa `docker compose down -v` (borra también métricas y trazas).

## Credenciales

- **Grafana**: abre sin login (anónimo, rol Editor). Si necesitas el usuario admin:

  ```bash
  grep GF_SECURITY_ADMIN_PASSWORD .env
  ```

- **Token admin de la falla**: lo leen `inject-fault.sh` y `recover.sh` desde `.env` y se lo pasan a
  `curl` por stdin (`curl -K -`), nunca como argumento visible en `ps`. Para llamar la API a mano:

  ```bash
  curl -s localhost:8001/admin/fault                          # estado actual (sin token)
  curl -s -X POST localhost:8001/admin/fault \
    -H "X-Fault-Admin-Token: $(grep '^FAULT_ADMIN_TOKEN=' .env | cut -d= -f2-)" \
    -H 'Content-Type: application/json' \
    -d '{"active": true, "latency_ms": 800, "error_rate": 0.1}'
  ```

Nunca pegues el contenido de `.env` en un issue, chat o captura de pantalla.

## Referencias

- Docker Compose - referencia CLI: https://docs.docker.com/compose/
- Grafana - configuración por variables de entorno: https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/
- Grafana - acceso anónimo: https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/grafana/#anonymous-authentication
- curl - archivos de configuración (`-K`): https://everything.curl.dev/cmdline/configfile
