"""Formatter de logging en JSON estructurado (idéntico patrón que shop-api).

Se duplica intencionalmente en cada servicio: son imágenes Docker
independientes y no comparten un paquete común instalado.
"""

import json
import logging
from datetime import datetime, timezone

_OPTIONAL_FIELDS = (
    "trace_id",
    "span_id",
    "order_id",
    "duration_ms",
    "outcome",
    "fault_active",
)


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "service": getattr(record, "service", "unknown"),
            "event": getattr(record, "event", record.getMessage()),
        }
        for field in _OPTIONAL_FIELDS:
            value = getattr(record, field, None)
            if value is not None:
                payload[field] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


def get_logger(service_name: str) -> logging.Logger:
    logger = logging.getLogger(service_name)
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(JsonFormatter())
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        logger.propagate = False
    return logger


def current_trace_context() -> dict:
    try:
        from opentelemetry import trace

        span = trace.get_current_span()
        ctx = span.get_span_context()
        if ctx is None or not ctx.is_valid:
            return {}
        return {
            "trace_id": format(ctx.trace_id, "032x"),
            "span_id": format(ctx.span_id, "016x"),
        }
    except Exception:  # pragma: no cover - defensivo
        return {}
