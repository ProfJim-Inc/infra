"""
OpenTelemetry distributed tracing setup.

What is distributed tracing?
    When a user makes an HTTP request, it might touch multiple services:
    frontend → API → database → cache → third-party API. A "trace" captures
    this entire call chain as a tree of "spans." Each span is one operation
    with a start time, duration, and metadata (attributes).

    Without tracing, you can see THAT a request is slow (from metrics) but not
    WHERE in the call chain the slowness is. Tracing shows you exactly which
    service and which operation is causing latency.

How it works in this service:
    1. FastAPIInstrumentor auto-creates a span for every HTTP request.
    2. Our code creates child spans for specific operations (see main.py).
    3. Each span is exported via OTLP/gRPC to the OTeL Collector.
    4. The Collector forwards spans to Grafana Tempo for storage.
    5. Grafana queries Tempo via TraceQL to display the trace UI.

    App ──OTLP/gRPC──► OTeL Collector ──► Grafana Tempo ──► Grafana UI

Environment variables:
    OTLP_ENDPOINT   gRPC endpoint for the OTeL Collector.
                    Default: otel-collector.monitoring.svc.cluster.local:4317
                    Set to "" to disable tracing (prints to stdout in dev mode).
    SERVICE_NAME    Name shown in Grafana trace search. Default: "demo-service"
    SERVICE_VERSION Shown as a resource attribute. Default: "0.1.0"
    ENV             Deployment environment label. Default: "production"
"""
import os
import logging

from opentelemetry import trace
from opentelemetry.sdk.resources import Resource, SERVICE_NAME, SERVICE_VERSION
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter

log = logging.getLogger("demo-service.telemetry")


def setup_tracing() -> None:
    """
    Initialise the global OpenTelemetry TracerProvider.

    This must be called once at application startup (in the FastAPI lifespan
    handler) before any spans are created. After this call, any code that does:

        tracer = trace.get_tracer("my-module")
        with tracer.start_as_current_span("my-operation"):
            ...

    will automatically send spans to the configured exporter.
    """
    service_name = os.getenv("SERVICE_NAME", "demo-service")
    service_version = os.getenv("SERVICE_VERSION", "0.1.0")
    otlp_endpoint = os.getenv(
        "OTLP_ENDPOINT",
        # In-cluster DNS: <service>.<namespace>.svc.cluster.local:<port>
        # Port 4317 is the standard OTLP/gRPC port.
        "http://otel-collector.monitoring.svc.cluster.local:4317",
    )

    # Resource describes the entity producing the telemetry.
    # These attributes are attached to every span and appear in Grafana as:
    #   service.name = "demo-service"
    #   service.version = "0.1.0"
    #   deployment.environment = "production"
    # Use them in Grafana TraceQL to filter: { service.name = "demo-service" }
    resource = Resource.create(
        {
            SERVICE_NAME: service_name,
            SERVICE_VERSION: service_version,
            "deployment.environment": os.getenv("ENV", "production"),
        }
    )

    # TracerProvider is the factory for Tracer objects. There is one global
    # provider per process. After set_tracer_provider() below, any call to
    # trace.get_tracer() will use this provider.
    provider = TracerProvider(resource=resource)

    if otlp_endpoint:
        # OTLP/gRPC exporter — sends spans to the OTeL Collector.
        # The Collector receives on port 4317 (gRPC) or 4318 (HTTP).
        # We use gRPC because it's more efficient for high-throughput tracing.
        #
        # Import inside the if-block so the app still starts if the grpc package
        # is missing in a minimal dev environment (unlikely but defensive).
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import (
            OTLPSpanExporter,
        )

        exporter = OTLPSpanExporter(
            endpoint=otlp_endpoint,
            insecure=True,  # no TLS needed for in-cluster communication
        )

        # BatchSpanProcessor buffers spans and sends them in batches.
        # This is much more efficient than sending each span individually (SimpleSpanProcessor).
        # The batch is flushed when it reaches a size limit or a time interval.
        provider.add_span_processor(BatchSpanProcessor(exporter))
        log.info("OTLP trace exporter configured", extra={"endpoint": otlp_endpoint})
    else:
        # Local dev fallback: print spans as JSON to stdout.
        # Set OTLP_ENDPOINT="" to use this mode when running without the K8s cluster.
        # Spans will appear in your terminal — useful for verifying instrumentation works.
        provider.add_span_processor(
            BatchSpanProcessor(ConsoleSpanExporter())
        )
        log.info("Console span exporter configured (no OTLP_ENDPOINT set)")

    # Register the provider globally. After this point, trace.get_tracer() and
    # trace.get_current_span() will use this provider.
    trace.set_tracer_provider(provider)

    # Auto-instrument FastAPI: wraps every route handler in a span.
    # The span is named after the HTTP method + path, e.g. "GET /api/v1/items".
    # It automatically records: http.method, http.url, http.status_code.
    # Any spans you create manually inside a handler become child spans of this auto-span.
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    FastAPIInstrumentor.instrument()
