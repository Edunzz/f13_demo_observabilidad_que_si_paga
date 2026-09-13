"""payment-service: procesa pagos y expone la API administrativa de fallas.

Endpoints:
- POST /pay            -> procesa un pago (puede degradarse si hay falla activa)
- GET  /health          -> liveness simple
- GET  /ready           -> siempre ready (sin dependencias externas duras)
- GET  /metrics         -> métricas Prometheus
- GET  /admin/fault     -> estado actual de la falla (sin auth)
- POST /admin/fault     -> activa/desactiva la falla (requiere token admin)
"""

import asyncio
import os
import random
import time

from fastapi import FastAPI, Header, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel

from src.fault_state import FaultStateStore, build_initial_state_from_env
from src.logging_utils import current_trace_context, get_logger
from src.metrics import FAULT_ACTIVE, PAYMENT_DURATION, PAYMENT_REQUESTS
from src.otel_setup import configure_otel

SERVICE_NAME = "payment-service"
FAULT_ADMIN_TOKEN = os.environ.get("FAULT_ADMIN_TOKEN", "CHANGE_ME")

logger = get_logger(SERVICE_NAME)

app = FastAPI(title="F13 payment-service")
tracer = configure_otel(app, SERVICE_NAME)

fault_store = FaultStateStore(build_initial_state_from_env())
FAULT_ACTIVE.set(1 if fault_store.snapshot().active else 0)


class PayRequest(BaseModel):
    order_id: str
    amount_usd: float


class FaultUpdate(BaseModel):
    active: bool
    latency_ms: int | None = None
    error_rate: float | None = None


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/ready")
async def ready():
    """payment-service no depende de ningún servicio externo para operar
    (el estado de la falla vive en memoria/local), así que siempre está
    ready si el proceso responde.
    """
    return {"status": "ready"}


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/admin/fault")
async def get_fault():
    state = fault_store.snapshot()
    return {"active": state.active, "latency_ms": state.latency_ms, "error_rate": state.error_rate}


@app.post("/admin/fault")
async def set_fault(update: FaultUpdate, x_fault_admin_token: str | None = Header(default=None)):
    if x_fault_admin_token != FAULT_ADMIN_TOKEN:
        return JSONResponse(status_code=401, content={"detail": "invalid admin token"})

    state = fault_store.update(
        active=update.active,
        latency_ms=update.latency_ms,
        error_rate=update.error_rate,
    )
    FAULT_ACTIVE.set(1 if state.active else 0)

    logger.info(
        "fault_state_changed",
        extra={
            "service": SERVICE_NAME,
            "event": "fault_state_changed",
            "outcome": "active" if state.active else "inactive",
            "fault_active": state.active,
        },
    )
    return {"active": state.active, "latency_ms": state.latency_ms, "error_rate": state.error_rate}


@app.post("/pay")
async def pay(payload: PayRequest):
    state = fault_store.snapshot()
    start = time.monotonic()

    with tracer.start_as_current_span("payment") as span:
        span.set_attribute("service.name", SERVICE_NAME)
        span.set_attribute("service.version", os.environ.get("SERVICE_VERSION", "0.1.0"))
        span.set_attribute("deployment.environment", os.environ.get("DEPLOYMENT_ENVIRONMENT", "demo"))
        span.set_attribute("business.operation", "payment")
        span.set_attribute("business.currency", "USD")
        span.set_attribute("fault.injected", state.active)

        outcome = "success"
        if state.active:
            # La falla inyecta latencia SIEMPRE (para que se note en p95/p99
            # aunque no haya error) y, con probabilidad `error_rate`, además
            # falla la transacción.
            await asyncio.sleep(state.latency_ms / 1000)
            if random.random() < state.error_rate:
                outcome = "error"

        duration_s = time.monotonic() - start
        duration_ms = duration_s * 1000

        span.set_attribute("business.payment.outcome", outcome)

        PAYMENT_REQUESTS.labels(outcome=outcome).inc()
        PAYMENT_DURATION.observe(duration_s)
        FAULT_ACTIVE.set(1 if state.active else 0)

        logger.info(
            "payment_processed",
            extra={
                "service": SERVICE_NAME,
                "event": "payment_processed",
                "order_id": payload.order_id,
                "duration_ms": round(duration_ms, 2),
                "outcome": outcome,
                "fault_active": state.active,
                **current_trace_context(),
            },
        )

        response_body = {
            "order_id": payload.order_id,
            "outcome": outcome,
            "amount_usd": payload.amount_usd,
            "duration_ms": round(duration_ms, 2),
            "fault_active": state.active,
        }
        status_code = 200 if outcome == "success" else 500
        return JSONResponse(status_code=status_code, content=response_body)
