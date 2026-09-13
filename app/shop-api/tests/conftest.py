import os
import sys

# Permite `from src.main import app` al correr pytest dentro de app/shop-api,
# sin necesidad de instalar el paquete.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

# Endpoint OTLP inválido a propósito: en tests no queremos exportar spans de
# verdad ni bloquear por reintentos de red al importar src.main.
os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")
os.environ.setdefault("PAYMENT_SERVICE_URL", "http://payment-service:8001")
