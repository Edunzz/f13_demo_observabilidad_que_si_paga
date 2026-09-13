"""Gauges de negocio/SLO expuestos por value-exporter (nombres EXACTOS)."""

from prometheus_client import Gauge

BUSINESS_REQUESTS_PER_MINUTE = Gauge(
    "f13_business_requests_per_minute", "Tráfico observado de checkouts por minuto"
)
BUSINESS_ERROR_RATE_RATIO = Gauge(
    "f13_business_error_rate_ratio", "Proporción de checkouts con outcome=error (0-1)"
)
BUSINESS_SUCCESS_RATE_RATIO = Gauge(
    "f13_business_success_rate_ratio", "Proporción de checkouts con outcome=success (0-1)"
)
BUSINESS_REVENUE_AT_RISK_USD_PER_MINUTE = Gauge(
    "f13_business_revenue_at_risk_usd_per_minute",
    "Ingreso en riesgo por minuto (USD, ilustrativo) debido a errores actuales",
)
BUSINESS_DEGRADATION_LOSS_USD_PER_MINUTE = Gauge(
    "f13_business_degradation_loss_usd_per_minute",
    "Pérdida por minuto (USD, ilustrativo) atribuible al abandono por degradación",
)
BUSINESS_ESTIMATED_LOSS_USD_TOTAL = Gauge(
    "f13_business_estimated_loss_usd_total",
    "Pérdida acumulada (USD, ilustrativo) desde el último reset del acumulador",
)
SLO_TARGET_RATIO = Gauge(
    "f13_slo_target_ratio", "SLO objetivo configurado (ej. 0.999)"
)
SLO_ERROR_BUDGET_REMAINING_RATIO = Gauge(
    "f13_slo_error_budget_remaining_ratio", "Fracción restante del error budget (0-1)"
)
