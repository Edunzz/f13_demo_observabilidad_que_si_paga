"""Formatter de logging en JSON estructurado (mismo patrón que los demás
servicios). load-generator NO está instrumentado con OpenTelemetry (no lo
exige el contrato: es solo un generador de tráfico), así que no incluye
trace_id/span_id — cada checkout inicia un trace nuevo del lado de shop-api,
lo cual es aceptable para esta demo.
"""

import json
import logging
from datetime import datetime, timezone

_OPTIONAL_FIELDS = ("order_id", "duration_ms", "outcome")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "service": getattr(record, "service", "load-generator"),
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
