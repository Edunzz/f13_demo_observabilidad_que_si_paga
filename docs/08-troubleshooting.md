# 08. Troubleshooting

Problemas comunes del laboratorio F13 en GitHub Codespaces y cómo resolverlos. Todos los comandos se
ejecutan en la terminal del Codespace, desde la raíz del repo.

| Problema | Síntoma | Causa probable | Solución |
|---|---|---|---|
| El laboratorio no arrancó | El Codespace abrió pero no aparecen URLs ni contenedores | El `postStartCommand` sigue corriendo (primera vez: 3–5 min) o falló | `bash scripts/status.sh`. Si no hay contenedores, corre `bash scripts/lab-up.sh` y lee el primer error que imprima. |
| Docker no responde | `lab-up.sh` se queda en "Esperando a que el daemon de Docker esté disponible" o falla tras 120 s | El daemon de la feature Docker-in-Docker aún no inició, o el devcontainer no se construyó con ella | Espera unos segundos y reintenta. Si persiste: paleta de comandos → **Codespaces: Rebuild Container**. |
| Healthcheck no pasa | `lab-up.sh` termina con "Timeout (300s) esperando healthchecks. No listos: …" | Un contenedor específico no llegó a `healthy` | `docker compose ps` para ver cuál, `docker compose logs --tail=100 <servicio>` para ver por qué, y `bash scripts/collect-diagnostics.sh` si necesitas compartir el diagnóstico. |
| Sin espacio en disco | Errores `no space left on device` en el build | Imágenes viejas acumuladas tras varios rebuilds | `docker system prune -f` y vuelve a correr `bash scripts/lab-up.sh`. |
| La URL pide iniciar sesión en GitHub | Al abrir Grafana/Jaeger desde otro navegador o compartir la URL, aparece el login de GitHub | El puerto está en visibilidad Private (por defecto en Codespaces, o `publish-ports.sh` no pudo cambiarlo) | `bash scripts/publish-ports.sh`, o pestaña **PORTS** → clic derecho en el puerto → *Port Visibility* → *Public*. Si tu organización lo prohíbe, compártelo desde tu sesión o usa puertos privados. |
| `publish-ports.sh` falla | "No se pudo cambiar la visibilidad (¿política de tu organización?)" | Política de la organización, o el puerto aún no estaba reenviado | Reintenta en unos segundos; si es política, el laboratorio funciona igual en privado. |
| Grafana no muestra los dashboards | Grafana carga pero no aparece la carpeta **F13** | El provisioning no se montó o un JSON es inválido | `docker compose logs grafana \| grep -i provision`. Confirma los montajes con `docker compose config` y que `observability/grafana/dashboards/*.json` sean JSON válidos. |
| Enlaces de Grafana apuntan a `localhost` | Un enlace compartido abre `http://localhost:3000/...` | `GF_SERVER_ROOT_URL` no se ajustó al Codespace (p. ej. `.env` creado fuera de Codespaces) | `bash scripts/setup-env.sh && docker compose up -d grafana`. |
| Jaeger sin trazas | La UI de Jaeger carga pero no aparecen `shop-api`/`payment-service` | El Collector no reenvía o las apps no exportan OTLP | `docker compose logs --tail=50 otel-collector` (errores de exportación); confirma `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317` en `.env`. El Collector no tiene healthcheck exec-based (imagen distroless); su extensión `health_check` responde en el puerto `13133` dentro de la red Docker. |
| `value-exporter` sin datos | Paneles de "F13 \| Impacto en el negocio" en "No data" | Prometheus aún no tiene histórico o `value-exporter` no completó su primer ciclo (cada 5 s) | Espera 1–2 ciclos. Si persiste: `docker compose logs --tail=50 value-exporter`, buscando `prometheus_query_failed`. |
| `inject-fault.sh` responde 401 | "POST /admin/fault respondió HTTP 401" | `payment-service` arrancó con un `FAULT_ADMIN_TOKEN` distinto al de `.env` (se editó `.env` sin recrear el contenedor) | `docker compose up -d payment-service` y reintenta. |
| El smoke test falla en `/checkout` con 502 | "shop-api /checkout respondió HTTP 502" | Hay una falla activa (30% de errores) | `bash scripts/recover.sh` y repite. |
| Las curvas no vuelven a cero tras `recover.sh` | Latencia o error rate siguen altos 1–2 minutos | Ventanas móviles de 1–5 minutos: comportamiento esperado | Espera; la pérdida acumulada no baja por diseño (es el costo total). `bash scripts/demo-reset.sh` la reinicia. |
| El Codespace se detuvo solo | Las URLs dejan de responder tras un rato sin usarlo | Tiempo de inactividad del Codespace | Ábrelo de nuevo: `lab-up.sh` levanta el stack al arrancar. Para demos largas, sube el *idle timeout* en GitHub → Settings → Codespaces. |

## Usar `collect-diagnostics.sh`

```bash
bash scripts/collect-diagnostics.sh
```

Genera `diagnostics/f13demo-diagnostics-<timestamp>.tar.gz` (ignorado por Git) con:

- `docker compose ps -a` y `docker compose config` (sanitizado: se redactan líneas con PASSWORD/TOKEN/SECRET).
- Los últimos 200 logs de cada contenedor.
- Uso de disco y memoria del Codespace.
- Resultado de los endpoints de salud de `shop-api`, Grafana, Jaeger, Prometheus, `payment-service` y
  `value-exporter`.

Antes de compartir el `.tar.gz` (issue, chat, ticket), revisa su contenido: el script no lee `.env` y
redacta lo que parezca credencial, pero confirmarlo tú mismo es buena práctica.

## Referencias

- Codespaces — solución de problemas: https://docs.github.com/codespaces/troubleshooting
- Docker Compose — comandos (`ps`, `logs`, `config`): https://docs.docker.com/compose/
- OpenTelemetry Collector — troubleshooting: https://opentelemetry.io/docs/collector/troubleshooting/
- Grafana — provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/
- Jaeger / OTLP: https://www.jaegertracing.io/docs/ y https://opentelemetry.io/docs/specs/otlp/
