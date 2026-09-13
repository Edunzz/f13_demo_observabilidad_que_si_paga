# 08. Troubleshooting

Tabla de problemas comunes del laboratorio F13 y cómo resolverlos. Todos los comandos indican
`[LOCAL]` o `[VM f13demo]`.

| Problema | Síntoma | Causa probable | Solución |
|---|---|---|---|
| `cloud-init` no termina | `scripts/remote-install.sh` se queda esperando en el Paso 3 ("esperando a que cloud-init termine") | Primer arranque de la VM aún instalando paquetes/Docker, o un paso de `runcmd` falló | Espera unos minutos más (el primer arranque puede tardar 3–5 min). Si sigue sin terminar, conéctate y revisa el log: `ssh azureuser@<PUBLIC_IP> "sudo tail -100 /var/log/f13demo-cloud-init.log"` `[LOCAL]`, y el estado exacto con `ssh azureuser@<PUBLIC_IP> "sudo cloud-init status --long"` `[LOCAL]`. |
| `docker compose` falla por versión | `remote-install.sh` falla en el Paso 6/12 ("docker compose (plugin v2) no está disponible") | El plugin Compose v2 no quedó instalado, o `install-docker.sh` de cloud-init falló a mitad de camino | `ssh azureuser@<PUBLIC_IP> "docker compose version"` `[LOCAL]` para confirmar. Si falta, reinstala manualmente siguiendo la guía oficial: https://docs.docker.com/engine/install/ubuntu/ `[VM f13demo]`, luego vuelve a correr `remote-install.sh` `[LOCAL]`. |
| Healthcheck no pasa | `remote-install.sh` falla en el Paso 10/12 ("Timeout esperando healthchecks") | Un contenedor específico no llegó a estado `healthy` dentro de los 5 minutos | Identifica cuál con `ssh azureuser@<PUBLIC_IP> "cd /opt/f13demo/repo && docker compose ps"` `[LOCAL]`, revisa sus logs con `docker compose logs --tail=100 <servicio>` `[VM f13demo]`, y considera correr `bash scripts/collect-diagnostics.sh` `[LOCAL]` para un diagnóstico completo antes de reintentar. |
| NSG bloquea el acceso porque cambió la IP del operador | `smoke-test.sh` o el navegador ya no llegan a la VM, pero antes funcionaban | Tu IP pública cambió (red distinta, VPN, reconexión de ISP) y las reglas del NSG siguen apuntando a la IP anterior | Vuelve a ejecutar `bash infra/azure/deploy.sh` `[LOCAL]`: el Paso 6 detecta automáticamente la IP nueva y actualiza solo el origen de las 4 reglas del NSG existentes, sin recrear nada más (ver `docs/02-despliegue-azure.md`). |
| Grafana no muestra los dashboards | Grafana carga pero las carpetas/dashboards "F13 \| Salud técnica" y "F13 \| Impacto en el negocio" no aparecen | El provisioning de dashboards/datasources no se montó o falló al parsear el JSON | Revisa `ssh azureuser@<PUBLIC_IP> "cd /opt/f13demo/repo && docker compose logs grafana \| grep -i provisioning"` `[VM f13demo]`. Confirma que los volúmenes `./observability/grafana/provisioning:/etc/grafana/provisioning:ro` y `./observability/grafana/dashboards:/var/lib/grafana/dashboards:ro` estén montados (`docker compose config`) y que los JSON de `observability/grafana/dashboards/*.json` sean válidos. Referencia: https://grafana.com/docs/grafana/latest/administration/provisioning/ |
| Jaeger sin trazas | La UI de Jaeger carga pero no aparecen trazas nuevas de `shop-api`/`payment-service` | `otel-collector` no está reenviando correctamente, o las apps no están exportando OTLP | Revisa `docker compose logs otel-collector` `[VM f13demo]` en busca de errores de exportación. Confirma que `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317` esté presente en `.env` remoto. El `otel-collector` no tiene healthcheck exec-based (su imagen no incluye shell/curl/wget), así que valida su extensión `health_check` interna en el puerto `13133` desde dentro de la VM: `ssh azureuser@<PUBLIC_IP> "curl -sf http://localhost:13133/ || echo FAIL"` `[LOCAL]`. |
| `value-exporter` sin datos | Los paneles del dashboard "F13 \| Impacto en el negocio" muestran "No data" | Prometheus todavía no tiene histórico suficiente (el stack acaba de arrancar) o `value-exporter` aún no completó su primer ciclo de polling (cada 5 s) | Espera 1–2 intervalos de scrape/polling. Si persiste, confirma que `value-exporter` puede alcanzar Prometheus: `ssh azureuser@<PUBLIC_IP> "cd /opt/f13demo/repo && docker compose logs value-exporter --tail=50"` `[VM f13demo]`, buscando líneas `prometheus_query_failed`. |
| El público no puede ver Prometheus en vivo | `smoke-test.sh` corrido `[LOCAL]` (contra la IP pública) omite el paso 3/5 de Prometheus | Comportamiento esperado, no un error: Prometheus (`9090`) nunca se publica al NSG (ver `docs/07-seguridad.md`) | Para validar Prometheus manualmente, hazlo siempre desde dentro de la VM: `TARGET_HOST=localhost bash scripts/smoke-test.sh` `[VM f13demo]` (por SSH), o abre un túnel SSH puntual si necesitas verlo desde tu navegador: `ssh -L 9090:localhost:9090 azureuser@<PUBLIC_IP>` `[LOCAL]`. |
| No sé cómo reportar un problema que no está en esta tabla | Algo falla y no es obvio por qué | — | Ejecuta `bash scripts/collect-diagnostics.sh` `[LOCAL]` (ver siguiente sección) y adjunta el `.tar.gz` generado al reportar el problema. |

## Usar `collect-diagnostics.sh`

```bash
# [LOCAL]
bash scripts/collect-diagnostics.sh
```

Este script recopila, por SSH, un paquete de diagnóstico local (`.tar.gz`, ignorado por Git gracias a
la entrada `*.tar.gz` en `.gitignore`) con, al menos:

- `docker compose ps` y `docker compose config` (validado).
- Logs recientes de todos los contenedores (`docker compose logs --tail=...`).
- Uso de disco y memoria de la VM.
- Resultado de los endpoints de salud (`/health`, `/api/health`, etc.).

Antes de compartir el `.tar.gz` con alguien (colega, ticket de soporte, hilo de GitHub), revisa
rápidamente su contenido: el propio script está diseñado para no incluir secretos (no captura `.env`
ni tokens), pero siempre es buena práctica confirmarlo tú mismo antes de adjuntar cualquier archivo
generado automáticamente.

## Referencias

- `cloud-init` — estado y logs: https://cloudinit.readthedocs.io/en/latest/howto/debugging.html
- Docker Compose — comandos (`ps`, `logs`, `config`): https://docs.docker.com/compose/
- OpenTelemetry Collector — configuración y troubleshooting: https://opentelemetry.io/docs/collector/
- Prometheus — consultas y almacenamiento: https://prometheus.io/docs/
- Grafana — provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/
- Jaeger / OTLP: https://www.jaegertracing.io/docs/ y https://opentelemetry.io/docs/specs/otlp/
