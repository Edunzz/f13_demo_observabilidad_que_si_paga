"""load-generator: tráfico sintético continuo contra shop-api.

No expone /metrics (no es necesario: shop-api ya registra
`f13_checkout_requests_total` / `f13_checkout_duration_seconds_bucket` del
lado servidor, que es la fuente de verdad para el resto del sistema). Este
script solo produce carga y deja rastro en logs JSON.
"""

import os
import time
import uuid

import httpx

from src.amounts import random_amount_usd
from src.logging_utils import get_logger

SERVICE_NAME = "load-generator"
SHOP_API_URL = os.environ.get("SHOP_API_URL", "http://shop-api:8000")

logger = get_logger(SERVICE_NAME)


def _load_settings():
    requests_per_minute = float(os.environ.get("REQUESTS_PER_MINUTE", "120"))
    average_request_value_usd = float(os.environ.get("AVERAGE_REQUEST_VALUE_USD", "50"))
    # LOAD_JITTER_RATIO es opcional: controla cuánto varían los montos
    # sintéticos alrededor de AVERAGE_REQUEST_VALUE_USD (0.2 = +/-20%).
    jitter_ratio = float(os.environ.get("LOAD_JITTER_RATIO", "0.2"))
    return requests_per_minute, average_request_value_usd, jitter_ratio


def run_forever() -> None:
    requests_per_minute, average_request_value_usd, jitter_ratio = _load_settings()
    sleep_seconds = 60.0 / max(requests_per_minute, 1.0)

    logger.info(
        "load_generator_started",
        extra={
            "service": SERVICE_NAME,
            "event": "load_generator_started",
        },
    )

    with httpx.Client(timeout=10.0) as client:
        while True:
            order_id = uuid.uuid4().hex[:8]
            amount_usd = random_amount_usd(average_request_value_usd, jitter_ratio)
            start = time.monotonic()
            outcome = "error"
            try:
                resp = client.post(
                    f"{SHOP_API_URL}/checkout",
                    json={"order_id": order_id, "amount_usd": amount_usd},
                )
                outcome = "success" if resp.status_code == 200 else "error"
            except httpx.HTTPError:
                outcome = "error"

            duration_ms = (time.monotonic() - start) * 1000

            logger.info(
                "checkout_request",
                extra={
                    "service": SERVICE_NAME,
                    "event": "checkout_request",
                    "order_id": order_id,
                    "duration_ms": round(duration_ms, 2),
                    "outcome": outcome,
                },
            )

            time.sleep(sleep_seconds)


if __name__ == "__main__":
    run_forever()
