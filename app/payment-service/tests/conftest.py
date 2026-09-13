import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")
os.environ.setdefault("FAULT_ADMIN_TOKEN", "test-token")
os.environ.setdefault("FAULT_LATENCY_MS", "10")
os.environ.setdefault("FAULT_ERROR_RATE", "0.30")
