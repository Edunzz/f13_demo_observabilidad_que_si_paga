"""Formatter de logging en JSON estructurado, sin dependencias pesadas.

Se usa `logging.Logger.info(..., extra={...})` para inyectar los campos de
negocio/observabilidad requeridos (trace_id, span_id, order_id, etc.). Ningún
campo con PII o secretos debe pasarse aquí (ver contrato del laboratorio).
"""

import json
import logging
from datetime import datetime, timezone

# Campos opcionales que, si están presentes en el LogRecord (via `extra=`),
# se incluyen en la salida JSON. `service` y `event` son casi siempre provistos.
_OPTIONAL_FIELDS = (
    "trace_id",
    "span_id",
    "order_id",
    "duration_ms",
    "outcome",
    "fault_active",
)


class JsonFormatter(logging.Formatter):
    """Formatea cada LogRecord como una línea JSON (un objeto por línea)."""

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
    """Crea (o reutiliza) un logger con el formatter JSON ya configurado."""
    logger = logging.getLogger(service_name)
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(JsonFormatter())
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        logger.propagate = False
    return logger


def current_trace_context() -> dict:
    """Extrae trace_id/span_id del span OTel activo (si existe) en formato hex.

    Se importa `opentelemetry.trace` de forma perezosa para no acoplar este
    módulo utilitario a que OTel esté siempre configurado (evita errores en
    tests unitarios que no levantan el SDK completo).
    """
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
    except Exception:  # pragma: no cover - defensivo, no debe romper logging
        return {}
