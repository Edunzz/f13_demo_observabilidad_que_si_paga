"""Definiciones de métricas Prometheus expuestas por shop-api.

IMPORTANTE: los nombres deben coincidir EXACTO con el contrato del laboratorio.
`prometheus_client` añade sufijos automáticamente según el tipo de métrica:
- Counter("f13_checkout_requests", ...)        -> expone f13_checkout_requests_total
- Histogram("f13_checkout_duration_seconds", ...) -> expone _bucket / _sum / _count
- Summary("f13_checkout_value_usd", ...)       -> expone _sum / _count (ver abajo)
"""

from prometheus_client import Counter, Histogram, Summary

# Contador de checkouts por resultado (outcome=success|error). Sin labels de
# alta cardinalidad (nada de order_id/customer_id/URL/trace_id).
CHECKOUT_REQUESTS = Counter(
    "f13_checkout_requests",
    "Cantidad de checkouts procesados, particionado por resultado",
    ["outcome"],
)

# Duración end-to-end del checkout (incluye la llamada a payment-service).
# Buckets en segundos pensados para latencias normales (ms) y la falla
# inyectada (hasta ~1.8s por defecto, dejamos margen hasta 10s).
CHECKOUT_DURATION = Histogram(
    "f13_checkout_duration_seconds",
    "Duración del checkout end-to-end en segundos",
    buckets=(0.05, 0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0),
)

# Elección de implementación para "f13_checkout_value_usd_sum":
# Usamos un Summary SIN cuantiles (no llamamos a ningún quantile), que solo
# acumula `_sum` (suma de los valores observados) y `_count` (cantidad de
# observaciones). Al llamar `.observe(amount_usd)` en cada checkout exitoso,
# `_sum` se comporta exactamente como el "sum acumulado de valor USD de
# checkouts exitosos" que pide el contrato, sin necesitar una métrica custom.
CHECKOUT_VALUE = Summary(
    "f13_checkout_value_usd",
    "Valor acumulado en USD de checkouts exitosos (solo _sum/_count, sin cuantiles)",
)
