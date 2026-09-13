# Versiones resueltas

Este archivo documenta las versiones concretas fijadas en `compose.yaml` y en las
imágenes base de los Dockerfiles del repositorio. Se actualiza cada vez que una
versión pinneada deja de existir o de ser soportada y se resuelve a una nueva
versión estable vigente. Nunca se usa la etiqueta `latest`.

| Componente | Versión fijada | Notas |
|---|---|---|
| Ubuntu (VM Azure) | 24.04 LTS (`Ubuntu2404` en `az vm create --image`) | Requisito obligatorio del laboratorio |
| Python (imágenes de `app/*`) | `python:3.12-slim` | Ver Dockerfiles de cada servicio en `app/` |
| otel-collector | `otel/opentelemetry-collector-contrib:0.160.0` | Verificado en Docker Hub, septiembre 2026 |
| Prometheus | `prom/prometheus:v3.14.0` | Verificado en Docker Hub, septiembre 2026 |
| Jaeger | `jaegertracing/all-in-one:1.76.0` | Última release de la línea Jaeger v1 (v1 llegó a EOL el 2025-12-31; Jaeger v2 usa un modelo de configuración distinto — ver comentario en `compose.yaml`). Migración a v2 queda documentada como trabajo futuro, no se implementa en este laboratorio. |
| Grafana | `grafana/grafana:13.2.1` | Verificado en Docker Hub, septiembre 2026 |

## Cómo reconciliar este archivo si una versión deja de existir

1. Verifica la versión estable vigente en el registro oficial del proyecto (Docker Hub / GitHub Releases).
2. Actualiza la etiqueta en `compose.yaml` (y en el `Dockerfile` correspondiente si aplica).
3. Actualiza la fila correspondiente en esta tabla, incluyendo la fecha de verificación.
4. Vuelve a correr `docker compose config --quiet`, `docker compose build --pull` y la suite de smoke tests antes de publicar el cambio.

## Dependencias Python fijadas

Cada servicio en `app/*/requirements.txt` fija versiones exactas (`==`) de sus
dependencias (FastAPI, Uvicorn, OpenTelemetry SDK/exporters/instrumentation,
prometheus-client, httpx, etc.). Consulta el `requirements.txt` de cada servicio
para el detalle; cualquier actualización de esas dependencias debe reflejarse
ahí y probarse con `pytest` (ver `app/*/tests/`) antes de fusionar cambios.
