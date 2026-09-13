# Imagen base fijada por tag específico (no "latest").
FROM python:3.12-slim

WORKDIR /app

# Usuario no root para ejecutar el proceso.
RUN groupadd --system appgroup && useradd --system --gid appgroup --no-create-home appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src

USER appuser

EXPOSE 8000

# HEALTHCHECK definido aquí (no delegado a docker-compose) para que la imagen
# sea autocontenida y funcione igual fuera de compose (ej. en un orquestador
# distinto). Usa el propio intérprete de Python para no depender de curl/wget
# instalados en la imagen slim.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=2)" || exit 1

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
