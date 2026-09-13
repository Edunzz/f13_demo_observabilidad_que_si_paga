# 07. Seguridad

Este documento resume el modelo de seguridad del laboratorio F13. Es un laboratorio de demostración
en una sola VM, no un diseño de referencia para producción; aun así, aplica controles básicos
razonables y los documenta explícitamente.

## Red: NSG restringido a `ADMIN_CIDR`

- El NSG `f13demo-nsg` (creado por `infra/azure/deploy.sh`) solo permite tráfico entrante desde
  `ADMIN_CIDR` (por defecto, la IP pública `/32` del operador, autodetectada; ver
  `docs/02-despliegue-azure.md`) hacia 4 puertos: `22` (SSH), `8080` (aplicación), `3000` (Grafana) y
  `16686` (Jaeger UI).
- Ningún otro puerto queda expuesto a Internet. En particular:
  - **Prometheus (`9090`) nunca se publica** al host de la VM ni al NSG: solo es alcanzable dentro de
    la red interna `f13demo-net` de Docker, o vía SSH con `TARGET_HOST=localhost` para
    `scripts/smoke-test.sh`.
  - **OTLP (`4317`/`4318`)** del `otel-collector` tampoco se publica: solo `shop-api` y
    `payment-service`, dentro de la misma red Docker, le envían trazas.
  - Los endpoints administrativos (`/admin/fault` en `payment-service:8001`,
    `/admin/reset-accumulator` en `value-exporter:9200`) tampoco se exponen al host ni al NSG; solo se
    alcanzan desde dentro de la VM, típicamente a través de `scripts/inject-fault.sh` /
    `scripts/recover.sh` / `scripts/demo-reset.sh` vía SSH.
- Si la IP pública del operador cambia entre sesiones, `deploy.sh` detecta la diferencia y actualiza
  **solo el origen** de las reglas existentes del NSG (ver `docs/08-troubleshooting.md`); nunca abre
  el rango a `0.0.0.0/0` de forma automática.

## SSH solo con clave pública

- La VM se crea con `--authentication-type ssh` y la clave pública indicada en
  `SSH_PUBLIC_KEY_PATH`; la autenticación por contraseña queda deshabilitada por defecto en imágenes
  Ubuntu de Azure creadas de esta forma.
- Ningún script de este laboratorio solicita ni transmite contraseñas SSH.

## Credenciales generadas automáticamente, nunca en Git

- `GF_SECURITY_ADMIN_PASSWORD` (Grafana) y `FAULT_ADMIN_TOKEN` (API admin de `payment-service`) se
  generan **dentro de la VM**, la primera vez que `scripts/remote-install.sh` crea el `.env` remoto a
  partir de `.env.example` (ver `docs/03-instalacion-demo.md`). Se generan con `openssl rand -base64
  24` (o `/dev/urandom` como fallback) y nunca viajan de vuelta a la máquina del operador ni se
  imprimen en la salida de ningún script.
- El archivo `.env.example` versionado en el repositorio solo contiene el placeholder `CHANGE_ME` para
  ambos valores; nunca un secreto real.
- `.gitignore` (raíz del repo) cubre explícitamente:

  ```text
  .env
  .f13demo-state.env
  *.pem
  *.key
  id_rsa
  id_ed25519
  *.tar.gz
  ```

  Esto evita que `.env` (con los secretos generados), `.f13demo-state.env` (con la IP pública y
  nombres de recursos), claves privadas, o los `.tar.gz` de `scripts/collect-diagnostics.sh` terminen
  commiteados por error.

## Sin contenedores privilegiados ni `docker.sock` montado

- Ningún servicio de `compose.yaml` corre en modo privilegiado ni monta `/var/run/docker.sock`.
- Cada contenedor corre con `restart: unless-stopped`, límites de logging (`json-file`, `max-size:
  10m`, `max-file: 3`) y, cuando la imagen lo permite, un healthcheck real (ver
  `docs/08-troubleshooting.md` para el caso de `otel-collector`, que no expone shell/curl/wget para un
  healthcheck exec-based).

## Retención de datos: política corta, apropiada para una demo

- **Jaeger**: almacenamiento `badger` de un solo nodo, persistido en el volumen `jaeger-badger-data`.
  Sobrevive a reinicios normales del contenedor, pero se pierde con `docker compose down -v` o con
  `destroy-lab-resources.sh`. No es un backend de producción (sin replicación).
- **Prometheus**: persistido en el volumen `prometheus-data`, sin configuración adicional de
  retención de largo plazo — suficiente para una demo de horas/días, no pensado para retener meses de
  histórico.
- **Grafana**: su base de datos interna (dashboards, sesiones) persiste en el volumen `grafana-data`;
  los dashboards "fuente de verdad" siguen siendo los JSON versionados en
  `observability/grafana/dashboards/`, provisionados automáticamente en cada arranque.

Ver la referencia oficial de Prometheus sobre almacenamiento y retención para el enfoque recomendado
en un entorno real: `{ref Prometheus storage https://prometheus.io/docs/prometheus/latest/storage/}`.

## Apagar el sistema operativo vs. desalojar la VM

Es una distinción importante para el control de costos (ver también `docs/09-limpieza-costos.md`):

| Acción | Comando | Efecto en facturación de cómputo |
|---|---|---|
| Apagar el SO desde dentro de la VM | `sudo shutdown -h now` `[VM f13demo]` | La VM queda en estado `stopped`, pero **el cómputo reservado sigue facturándose** porque el hardware sigue asignado. |
| Desasignar (deallocate) la VM | `az vm deallocate ...` (o `bash infra/azure/stop.sh` `[LOCAL]`) | La VM queda en estado `stopped (deallocated)`; **se detiene la facturación de cómputo**. El disco administrado sigue facturándose en ambos casos. |

`scripts`/`infra/azure/stop.sh` siempre usa `az vm deallocate`, nunca un simple `shutdown` remoto, para
asegurar que efectivamente se detenga el costo de cómputo.

## Resumen de superficie expuesta

| Puerto | Servicio | Expuesto a Internet (vía NSG) |
|---|---|---|
| 22 | SSH | Sí, solo desde `ADMIN_CIDR` |
| 8080 | `shop-api` (aplicación) | Sí, solo desde `ADMIN_CIDR` |
| 3000 | Grafana | Sí, solo desde `ADMIN_CIDR` |
| 16686 | Jaeger UI | Sí, solo desde `ADMIN_CIDR` |
| 9090 | Prometheus | No, nunca |
| 4317 / 4318 | OTLP (otel-collector) | No, nunca |
| 8001 | API admin de `payment-service` | No, nunca (solo interno vía SSH) |
| 9200 | API admin de `value-exporter` | No, nunca (solo interno vía SSH) |

## Referencias

- Azure — grupos de seguridad de red (NSG): https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview
- Azure CLI — `az vm deallocate`: https://learn.microsoft.com/en-us/cli/azure/vm#az-vm-deallocate
- Docker — buenas prácticas de seguridad de contenedores: https://docs.docker.com/engine/security/
- Prometheus — almacenamiento y retención: https://prometheus.io/docs/prometheus/latest/storage/
- Grafana — provisioning (datasources/dashboards y credenciales de administrador):
  https://grafana.com/docs/grafana/latest/administration/provisioning/
