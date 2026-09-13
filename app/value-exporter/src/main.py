"""value-exporter: exportador derivado que traduce métricas técnicas de
shop-api/payment-service en métricas de negocio/SLO (patrón exportador
derivado: hace polling a la API de Prometheus y re-expone gauges calculados
en su propio /metrics, para que Prometheus lo vuelva a scrapear).

Todos los valores financieros son ILUSTRATIVOS (ver `src/formulas.py`).
"""

import asyncio
import logging
import os
import time
from dataclasses import dataclass

import httpx
from fastapi import FastAPI, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from src.formulas import (
    accumulate_loss_usd,
    conversions_per_minute,
    ingreso_en_riesgo_usd_min,
    perdida_degradacion_usd_min,
    slo_error_budget_remaining_ratio,
)
from src.metrics import (
    BUSINESS_DEGRADATION_LOSS_USD_PER_MINUTE,
    BUSINESS_ERROR_RATE_RATIO,
    BUSINESS_ESTIMATED_LOSS_USD_TOTAL,
    BUSINESS_REQUESTS_PER_MINUTE,
    BUSINESS_REVENUE_AT_RISK_USD_PER_MINUTE,
    BUSINESS_SUCCESS_RATE_RATIO,
    SLO_ERROR_BUDGET_REMAINING_RATIO,
    SLO_TARGET_RATIO,
)
from src.prom_query import query_instant

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("value-exporter")

POLL_INTERVAL_SECONDS = 5.0

Q_SUCCESS_RATE_PER_SEC = 'sum(rate(f13_checkout_requests_total{outcome="success"}[1m]))'
Q_ERROR_RATE_PER_SEC = 'sum(rate(f13_checkout_requests_total{outcome="error"}[1m]))'
Q_FAULT_ACTIVE = "max(f13_fault_active)"


@dataclass
class Settings:
    prometheus_url: str
    requests_per_minute_fallback: float
    average_request_value_usd: float
    baseline_abandonment_rate: float
    degraded_abandonment_rate: float
    average_ticket_usd: float
    slo_target_ratio: float

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            prometheus_url=os.environ.get("PROMETHEUS_URL", "http://prometheus:9090"),
            requests_per_minute_fallback=float(os.environ.get("REQUESTS_PER_MINUTE", "120")),
            average_request_value_usd=float(os.environ.get("AVERAGE_REQUEST_VALUE_USD", "50")),
            baseline_abandonment_rate=float(os.environ.get("BASELINE_ABANDONMENT_RATE", "0.10")),
            degraded_abandonment_rate=float(os.environ.get("DEGRADED_ABANDONMENT_RATE", "0.35")),
            average_ticket_usd=float(os.environ.get("AVERAGE_TICKET_USD", "50")),
            slo_target_ratio=float(os.environ.get("SLO_TARGET_RATIO", "0.999")),
        )


class ExporterState:
    """Estado mutable compartido entre el loop de polling y el endpoint de reset."""

    def __init__(self) -> None:
        self.lock = asyncio.Lock()
        self.last_poll_monotonic: float | None = None
        self.accumulated_loss_usd: float = 0.0

    async def reset(self) -> None:
        async with self.lock:
            self.accumulated_loss_usd = 0.0
            self.last_poll_monotonic = time.monotonic()


settings = Settings.from_env()
state = ExporterState()

app = FastAPI(title="F13 value-exporter")

# El SLO objetivo es una constante de configuración (no depende de polling),
# se fija una sola vez al arrancar.
SLO_TARGET_RATIO.set(settings.slo_target_ratio)


async def poll_once(client: httpx.AsyncClient) -> None:
    """Un ciclo de polling: lee Prometheus, recalcula fórmulas de negocio y
    actualiza los gauges. Si Prometheus no responde, deja los gauges de
    negocio en su último valor conocido (no los pisa con ceros) y solo
    registra un warning.
    """
    success_ps = await query_instant(client, settings.prometheus_url, Q_SUCCESS_RATE_PER_SEC)
    error_ps = await query_instant(client, settings.prometheus_url, Q_ERROR_RATE_PER_SEC)
    fault_raw = await query_instant(client, settings.prometheus_url, Q_FAULT_ACTIVE)

    if success_ps is None or error_ps is None or fault_raw is None:
        logger.warning("prometheus_query_failed url=%s", settings.prometheus_url)
        # Avanzamos el reloj de "última muestra" para no acumular pérdida por
        # el hueco de la falla de conexión cuando vuelva a responder.
        async with state.lock:
            state.last_poll_monotonic = time.monotonic()
        return

    total_ps = success_ps + error_ps
    if total_ps > 0:
        error_rate = error_ps / total_ps
        success_rate = success_ps / total_ps
        requests_per_minute = total_ps * 60.0
    else:
        # Sin tráfico observado todavía: asumimos 0 errores, no aplicamos el
        # fallback estático (sería engañoso reportar tráfico "de env" cuando
        # Prometheus sí respondió pero aún no hay series).
        error_rate = 0.0
        success_rate = 1.0
        requests_per_minute = 0.0

    fault_active = fault_raw >= 1.0

    conv_per_min = conversions_per_minute(requests_per_minute, success_rate)
    abandonment_now = settings.degraded_abandonment_rate if fault_active else settings.baseline_abandonment_rate

    revenue_at_risk = ingreso_en_riesgo_usd_min(error_rate, requests_per_minute, settings.average_request_value_usd)
    degradation_loss = perdida_degradacion_usd_min(
        abandonment_now, settings.baseline_abandonment_rate, conv_per_min, settings.average_ticket_usd
    )
    slo_remaining = slo_error_budget_remaining_ratio(settings.slo_target_ratio, success_rate)

    now = time.monotonic()
    async with state.lock:
        elapsed_minutes = 0.0
        if state.last_poll_monotonic is not None:
            elapsed_minutes = (now - state.last_poll_monotonic) / 60.0
        state.last_poll_monotonic = now

        loss_per_minute_total = revenue_at_risk + degradation_loss
        if fault_active:
            state.accumulated_loss_usd = accumulate_loss_usd(
                state.accumulated_loss_usd, loss_per_minute_total, elapsed_minutes
            )
        accumulated = state.accumulated_loss_usd

    BUSINESS_REQUESTS_PER_MINUTE.set(requests_per_minute)
    BUSINESS_ERROR_RATE_RATIO.set(error_rate)
    BUSINESS_SUCCESS_RATE_RATIO.set(success_rate)
    BUSINESS_REVENUE_AT_RISK_USD_PER_MINUTE.set(revenue_at_risk)
    BUSINESS_DEGRADATION_LOSS_USD_PER_MINUTE.set(degradation_loss)
    BUSINESS_ESTIMATED_LOSS_USD_TOTAL.set(accumulated)
    SLO_ERROR_BUDGET_REMAINING_RATIO.set(slo_remaining)


async def poll_loop() -> None:
    async with httpx.AsyncClient() as client:
        while True:
            try:
                await poll_once(client)
            except Exception:  # pragma: no cover - red de seguridad del loop
                logger.exception("unexpected_error_in_poll_loop")
            await asyncio.sleep(POLL_INTERVAL_SECONDS)


@app.on_event("startup")
async def on_startup() -> None:
    asyncio.create_task(poll_loop())


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/admin/reset-accumulator")
async def reset_accumulator():
    """Reinicia `f13_business_estimated_loss_usd_total` a 0.

    LIMITACIÓN DOCUMENTADA: sin autenticación adicional a propósito. Este
    endpoint es solo para uso local de `demo-reset.sh` en el laboratorio; no
    debe exponerse en un entorno compartido/productivo sin agregar auth.
    """
    await state.reset()
    BUSINESS_ESTIMATED_LOSS_USD_TOTAL.set(0.0)
    return {"status": "reset"}
