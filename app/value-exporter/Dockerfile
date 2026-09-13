# Imagen base fijada por tag específico (no "latest").
FROM python:3.12-slim

WORKDIR /app

RUN groupadd --system appgroup && useradd --system --gid appgroup --no-create-home appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src

USER appuser

EXPOSE 9200

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:9200/health', timeout=2)" || exit 1

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "9200"]
