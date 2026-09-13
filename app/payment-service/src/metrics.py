"""Métricas Prometheus de payment-service (nombres EXACTOS del contrato)."""

from prometheus_client import Counter, Gauge, Histogram

# Counter("f13_payment_requests", ...) -> expone f13_payment_requests_total
PAYMENT_REQUESTS = Counter(
    "f13_payment_requests",
    "Cantidad de pagos procesados, particionado por resultado",
    ["outcome"],
)

PAYMENT_DURATION = Histogram(
    "f13_payment_duration_seconds",
    "Duración del procesamiento de pago en segundos",
    buckets=(0.05, 0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0),
)

# Gauge 0|1: refleja si la falla inyectada está activa en este momento.
FAULT_ACTIVE = Gauge(
    "f13_fault_active",
    "1 si la falla inyectada está activa, 0 en caso contrario",
)
