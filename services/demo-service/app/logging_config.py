"""
Structured JSON logging to stdout.

Why structured logging?
    Traditional logs look like:
        2024-01-15 12:34:56 ERROR Failed to process request: connection timeout

    Structured JSON logs look like:
        {"timestamp":"2024-01-15T12:34:56Z","level":"ERROR","message":"Failed to
         process request","error":"connection timeout","trace_id":"abc123","item_id":42}

    The second form is machine-parseable. Fluent Bit ships the raw JSON to OpenSearch,
    which indexes every field. This means you can filter by any combination of fields
    (level=ERROR AND item_id=42) and link directly to the trace in Grafana Tempo.

The logging pipeline:
    This service writes JSON to stdout
    Fluent Bit tails /var/log/containers/*.log on the node
    Fluent Bit enriches with K8s metadata (pod name, namespace, labels)
    Fluent Bit writes to OpenSearch: index logs-demo-service-YYYY.MM.DD
    Grafana queries OpenSearch to display logs in the Explore panel

Trace correlation:
    Each log line includes trace_id and span_id from the active OpenTelemetry span.
    In Grafana, you can click from a log line directly to the trace that produced it.
    This requires the OpenSearch datasource to be configured with tracesToLogsV2 -> Tempo.

Fields emitted per log line:
    timestamp    ISO-8601 UTC timestamp of the log event
    level        Log level: DEBUG, INFO, WARNING, ERROR, CRITICAL
    logger       Logger name (e.g., "demo-service", "demo-service.telemetry")
    message      The log message string
    trace_id     Active OTeL trace ID (32 hex chars) — only present inside a span
    span_id      Active OTeL span ID (16 hex chars) — only present inside a span
    ...          Any additional fields passed via extra={} in the log call
"""
import json
import logging
import os
import time
from opentelemetry import trace


class JsonFormatter(logging.Formatter):
    """
    Custom logging.Formatter that emits one JSON object per log line.

    Usage:
        log.info("item created", extra={"item_id": 42, "category": "hardware"})

    Output:
        {"timestamp":"2024-01-15T12:34:56Z","level":"INFO","logger":"demo-service",
         "message":"item created","trace_id":"abc...","span_id":"def...","item_id":42,
         "category":"hardware"}

    The extra={} kwargs are forwarded as top-level JSON fields, making them
    searchable in OpenSearch without any additional parsing configuration.
    """

    # Python's logging.LogRecord has many internal bookkeeping fields that we
    # don't want to surface in the JSON output (they're redundant or implementation details).
    # This set lists every field to skip when iterating over record.__dict__.
    _SKIP = frozenset(
        (
            "args",            # the raw format args — already included in message
            "created",         # epoch float — we use our own timestamp format
            "exc_info",        # exception tuple — handled separately below
            "exc_text",        # cached exception text
            "filename",        # source file — too low-level for prod logs
            "funcName",        # function name — too low-level
            "levelno",         # numeric level — we use levelname (string)
            "lineno",          # source line number — too low-level
            "module",          # module name — too low-level
            "msecs",           # milliseconds part of timestamp — not needed
            "msg",             # raw message before format — we use getMessage()
            "name",            # logger name — included as "logger"
            "pathname",        # full file path — too verbose
            "process",         # PID
            "processName",     # process name
            "relativeCreated", # ms since logging was initialized
            "stack_info",      # stack trace (non-exception)
            "taskName",        # asyncio task name (Python 3.12+)
            "thread",          # thread ID
            "threadName",      # thread name
        )
    )

    def format(self, record: logging.LogRecord) -> str:
        """Render a LogRecord as a single JSON line."""

        # Build the base object with the fields we always want.
        obj: dict = {
            "timestamp": time.strftime(
                "%Y-%m-%dT%H:%M:%SZ",
                time.gmtime(record.created)    # UTC — always use UTC in server logs
            ),
            "level":   record.levelname,
            "logger":  record.name,
            "message": record.getMessage(),    # handles % formatting in the message
        }

        # ---------------------------------------------------------------------------
        # OTeL trace/span ID injection
        #
        # get_current_span() returns the span executing on this thread/asyncio task.
        # Inside a "with tracer.start_as_current_span(...):" block (or inside a
        # FastAPI handler that was auto-instrumented), this will be a real span.
        #
        # Outside any span (e.g., during startup logging), get_current_span() returns
        # a no-op span and ctx.is_valid is False — we skip the trace fields in that case.
        #
        # trace_id: 32 lowercase hex chars (128-bit). Grafana expects this exact format.
        # span_id:  16 lowercase hex chars (64-bit).
        # ---------------------------------------------------------------------------
        span = trace.get_current_span()
        ctx = span.get_span_context()
        if ctx.is_valid:
            obj["trace_id"] = format(ctx.trace_id, "032x")
            obj["span_id"] = format(ctx.span_id, "016x")

        # Forward any extra={...} fields the caller passed.
        # e.g., log.info("created", extra={"item_id": 42}) adds "item_id": 42 to the JSON.
        for key, value in record.__dict__.items():
            if key not in self._SKIP and not key.startswith("_") and key not in obj:
                obj[key] = value

        # Include exception tracebacks as a separate field — not inline — so the
        # output remains one valid JSON object per line.
        if record.exc_info:
            obj["exception"] = self.formatException(record.exc_info)

        # default=str handles non-JSON-serializable values (datetimes, UUIDs, etc.)
        return json.dumps(obj, default=str)


def configure_logging() -> logging.Logger:
    """
    Configure the root logger to use JsonFormatter and return the service logger.

    Call this once at application startup before any other loggers are created.
    After this call, ALL loggers in the process (including libraries) emit JSON.

    Environment variables:
        LOG_LEVEL   Minimum log level. Default: "INFO".
                    Options: DEBUG, INFO, WARNING, ERROR, CRITICAL.
    """
    level = os.getenv("LOG_LEVEL", "INFO").upper()

    # StreamHandler writes to stdout — Fluent Bit and `kubectl logs` read stdout.
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())

    # Configure the root logger — all other loggers inherit from it.
    root = logging.getLogger()
    root.handlers = [handler]    # replace any existing handlers
    root.setLevel(level)

    # Quieten noisy libraries:
    #   uvicorn.access: logs every HTTP request in its own format, which duplicates
    #                   what FastAPIInstrumentor already captures as a trace span.
    #   opentelemetry:  its own internal logging is verbose at DEBUG level.
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("opentelemetry").setLevel(logging.WARNING)

    # Return the top-level service logger.
    # In main.py: log = configure_logging()
    # All child loggers (e.g., logging.getLogger("demo-service.telemetry")) inherit
    # the same handler and level.
    return logging.getLogger("demo-service")
