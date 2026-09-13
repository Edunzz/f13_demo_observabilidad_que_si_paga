"""shop-api: punto de entrada del checkout del sistema de ejemplo F13.

Expone:
- POST /checkout  -> orquesta el cobro llamando a payment-service
- GET  /health     -> liveness simple
- GET  /ready      -> readiness (ver nota más abajo)
- GET  /metrics    -> métricas Prometheus (texto plano)
"""

import os
import time
import uuid

import httpx
from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel

from src.logging_utils import current_trace_context, get_logger
from src.metrics import CHECKOUT_DURATION, CHECKOUT_REQUESTS, CHECKOUT_VALUE
from src.otel_setup import configure_otel

SERVICE_NAME = "shop-api"
PAYMENT_SERVICE_URL = os.environ.get("PAYMENT_SERVICE_URL", "http://payment-service:8001")

logger = get_logger(SERVICE_NAME)

app = FastAPI(title="F13 shop-api")
tracer = configure_otel(app, SERVICE_NAME)


class CheckoutRequest(BaseModel):
    order_id: str | None = None
    amount_usd: float


@app.get("/health")
async def health():
    """Liveness: si el proceso responde, está vivo. No valida dependencias."""
    return {"status": "ok"}


@app.get("/ready")
async def ready():
    """Readiness: shop-api NO puede completar ningún checkout sin
    payment-service, así que consideramos que es una dependencia dura y la
    verificamos con un timeout corto para no bloquear el probe. Si
    payment-service no responde, devolvemos 503 (not ready).
    """
    try:
        async with httpx.AsyncClient(timeout=0.5) as client:
            resp = await client.get(f"{PAYMENT_SERVICE_URL}/health")
        if resp.status_code == 200:
            return {"status": "ready"}
    except httpx.HTTPError:
        pass
    return JSONResponse(status_code=503, content={"status": "not_ready"})


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/checkout")
async def checkout(payload: CheckoutRequest):
    order_id = payload.order_id or uuid.uuid4().hex[:8]
    start = time.monotonic()

    with tracer.start_as_current_span("checkout") as span:
        span.set_attribute("service.name", SERVICE_NAME)
        span.set_attribute("service.version", os.environ.get("SERVICE_VERSION", "0.1.0"))
        span.set_attribute("deployment.environment", os.environ.get("DEPLOYMENT_ENVIRONMENT", "demo"))
        span.set_attribute("business.operation", "checkout")
        span.set_attribute("business.currency", "USD")

        outcome = "error"
        fault_active = False
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.post(
                    f"{PAYMENT_SERVICE_URL}/pay",
                    json={"order_id": order_id, "amount_usd": payload.amount_usd},
                )
            body = resp.json()
            outcome = body.get("outcome", "success" if resp.status_code == 200 else "error")
            fault_active = bool(body.get("fault_active", False))
        except (httpx.HTTPError, ValueError):
            # Fallo de red/timeout o respuesta no-JSON de payment-service:
            # lo tratamos como checkout fallido, sin propagar detalles internos.
            outcome = "error"

        duration_s = time.monotonic() - start
        duration_ms = duration_s * 1000

        span.set_attribute("business.payment.outcome", outcome)
        span.set_attribute("fault.injected", fault_active)

        CHECKOUT_REQUESTS.labels(outcome=outcome).inc()
        CHECKOUT_DURATION.observe(duration_s)
        if outcome == "success":
            CHECKOUT_VALUE.observe(payload.amount_usd)

        logger.info(
            "checkout_processed",
            extra={
                "service": SERVICE_NAME,
                "event": "checkout_processed",
                "order_id": order_id,
                "duration_ms": round(duration_ms, 2),
                "outcome": outcome,
                "fault_active": fault_active,
                **current_trace_context(),
            },
        )

        response_body = {
            "order_id": order_id,
            "outcome": outcome,
            "amount_usd": payload.amount_usd,
            "duration_ms": round(duration_ms, 2),
        }
        status_code = 200 if outcome == "success" else 502
        return JSONResponse(status_code=status_code, content=response_body)
