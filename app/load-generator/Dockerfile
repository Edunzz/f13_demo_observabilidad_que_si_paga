# Imagen base fijada por tag específico (no "latest").
FROM python:3.12-slim

WORKDIR /app

RUN groupadd --system appgroup && useradd --system --gid appgroup --no-create-home appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src

USER appuser

# Sin EXPOSE: no sirve tráfico entrante, es un cliente en loop.
# Sin HEALTHCHECK: no hay endpoint que consultar; el propio orquestador
# (docker-compose) puede vigilar el estado del proceso (`docker ps`/restart
# policy) en su lugar.
CMD ["python", "-m", "src.main"]
