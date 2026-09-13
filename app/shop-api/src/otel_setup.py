"""Configuración de OpenTelemetry (tracing) para shop-api.

Exporta spans vía OTLP/gRPC al endpoint definido en `OTEL_EXPORTER_OTLP_ENDPOINT`
(por defecto apunta al otel-collector del docker-compose). Instrumenta FastAPI
(spans entrantes) y httpx (spans salientes hacia payment-service), propagando
W3C Trace Context automáticamente (comportamiento por defecto del SDK OTel).
"""

import os

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


def configure_otel(app, service_name: str) -> trace.Tracer:
    """Inicializa el TracerProvider global y instrumenta la app FastAPI + httpx."""
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")

    resource = Resource.create(
        {
            "service.name": service_name,
            "service.version": os.environ.get("SERVICE_VERSION", "0.1.0"),
            "deployment.environment": os.environ.get("DEPLOYMENT_ENVIRONMENT", "demo"),
        }
    )

    provider = TracerProvider(resource=resource)
    # insecure=True: el otel-collector de la demo no usa TLS entre contenedores.
    exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    FastAPIInstrumentor.instrument_app(app)
    HTTPXClientInstrumentor().instrument()

    return trace.get_tracer(service_name)
