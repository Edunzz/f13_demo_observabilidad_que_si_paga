# 07. Seguridad (modo demo)

Este documento resume el modelo de seguridad del laboratorio F13 en GitHub Codespaces. Es un
laboratorio de **demostración**, no un diseño de referencia para producción: prioriza que cualquiera
pueda abrirlo y explorarlo sin fricción, y documenta explícitamente qué se expone y qué no.

## HTTP plano, sin TLS

- Todos los servicios (Grafana, Jaeger, Prometheus, `shop-api`, `payment-service`, `value-exporter`,
  Collector) hablan **HTTP plano**. No hay certificados ni configuración TLS en el repositorio.
- `devcontainer.json` declara `"protocol": "http"` en cada puerto: Codespaces habla HTTP con el
  servicio.
- La URL que abre el navegador (`<codespace>-<puerto>.app.github.dev`) pasa por el proxy de port
  forwarding de GitHub, que GitHub sirve con su propio `https` en el borde. No es configuración del
  laboratorio ni se puede desactivar.

## Qué se publica y qué no

`scripts/lab-up.sh` llama a `scripts/publish-ports.sh`, que deja en visibilidad **Public** solo los
puertos web, para que puedas compartir las URLs durante la demo:

| Puerto | Servicio | Visibilidad | Notas |
|---|---|---|---|
| `3000` | Grafana | Public | Acceso anónimo con rol Editor (ver abajo) |
| `16686` | Jaeger UI | Public | Solo lectura de trazas de la demo |
| `9090` | Prometheus | Public | Sin `--web.enable-lifecycle`: nadie puede apagarlo ni recargarlo por HTTP |
| `8080` | `shop-api` | Public | Cualquiera con la URL puede generar checkouts de prueba |
| `8001` | API admin de `payment-service` | **No se reenvía** | Escucha solo en `127.0.0.1` del Codespace; `POST /admin/fault` exige token |
| `9200` | `value-exporter` (`/metrics`, reset del acumulador) | **No se reenvía** | Escucha solo en `127.0.0.1` del Codespace |
| `4317`/`4318` | OTLP del Collector | **No se publica** | Solo dentro de la red Docker `f13demo-net` |

Consecuencia práctica: **la falla solo se puede inyectar o recuperar desde la terminal del Codespace**,
nunca desde una URL pública.

Para volver a puertos privados (solo tu cuenta de GitHub puede abrirlos):

```bash
bash scripts/publish-ports.sh --private
```

Si tu organización prohíbe puertos públicos, `publish-ports.sh` avisa y el laboratorio sigue
funcionando con puertos privados.

## Grafana: acceso anónimo

- `GF_AUTH_ANONYMOUS_ENABLED=true` con rol `Editor`, para ver dashboards y usar **Explore** sin login.
- Los dashboards provisionados no se pueden sobrescribir desde la UI (`allowUiUpdates: false`): la
  fuente de verdad son los JSON de `observability/grafana/dashboards/`.
- Si publicas el puerto 3000 y no quieres que terceros editen o creen dashboards, pon
  `GF_AUTH_ANONYMOUS_ENABLED=false` en `.env`, aplica con `docker compose up -d` y entra con el usuario
  `admin` (contraseña en `.env`).

## Secretos generados en el Codespace, nunca en Git

- `GF_SECURITY_ADMIN_PASSWORD` y `FAULT_ADMIN_TOKEN` se generan con `openssl rand -hex 24` dentro del
  Codespace, la primera vez que `scripts/setup-env.sh` crea `.env` (permisos `600`). Ningún script los
  imprime.
- `inject-fault.sh`, `recover.sh` y `smoke-test.sh` pasan las credenciales a `curl` por stdin
  (`curl -K -`), nunca como argumentos visibles en `ps`.
- `.env.example` solo contiene el placeholder `CHANGE_ME`. `.gitignore` cubre `.env`, claves privadas,
  `*.tar.gz` y `diagnostics/`. El CI corre gitleaks en cada push.

## Contenedores

- Ningún servicio de `compose.yaml` corre en modo privilegiado ni monta `/var/run/docker.sock`. (El
  devcontainer sí usa la feature Docker-in-Docker, que requiere un contenedor privilegiado: es la
  forma estándar de tener Docker dentro de un Codespace.)
- Las imágenes de las apps corren con usuario no root; todas las imágenes de terceros están fijadas por
  versión (ver `VERSIONS.md`).
- Límites de logging (`json-file`, `max-size: 10m`, `max-file: 3`) y healthchecks reales donde la
  imagen lo permite.

## Retención de datos

- **Jaeger** (`badger`), **Prometheus** y **Grafana** persisten en volúmenes Docker dentro del
  Codespace: sobreviven a `docker compose restart` y a detener/arrancar el Codespace, y se pierden con
  `docker compose down -v` o al borrar el Codespace.
- No hay retención de largo plazo: es suficiente para una demo de horas, no para meses de histórico.

## Referencias

- Port forwarding y visibilidad en Codespaces: https://docs.github.com/codespaces/developing-in-a-codespace/forwarding-ports-in-your-codespace
- Restringir la visibilidad de puertos en una organización: https://docs.github.com/codespaces/managing-codespaces-for-your-organization/restricting-the-visibility-of-forwarded-ports
- Grafana - autenticación anónima: https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/grafana/#anonymous-authentication
- Prometheus - flags de línea de comandos (`--web.enable-lifecycle`): https://prometheus.io/docs/prometheus/latest/command-line/prometheus/
- Docker - seguridad de contenedores: https://docs.docker.com/engine/security/
