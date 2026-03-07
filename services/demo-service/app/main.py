"""
demo-service — Infrastructure showcase service.

Demonstrates all three observability pillars on the Creatium stack:
  - Traces  → OTeL Collector → Grafana Tempo  → Grafana "Explore > Tempo"
  - Metrics → Prometheus (via /metrics scrape) → Grafana dashboards
  - Logs    → stdout → Fluent Bit → OpenSearch → Grafana "Explore > OpenSearch"

Endpoints worth hitting to generate interesting telemetry:
  GET  /api/v1/items          — list items (fast path, counter + histogram)
  POST /api/v1/items          — create item (writes to in-memory store)
  GET  /api/v1/items/{id}     — fetch one item (404 if missing → error span)
  GET  /api/v1/slow?delay=2.0 — artificial delay (shows latency in Grafana)
  GET  /api/v1/error          — intentional 500 (shows error traces in Tempo)
  GET  /metrics               — Prometheus metrics endpoint
  GET  /health                — liveness probe
  GET  /readiness             — readiness probe
"""

import asyncio
import os
import time
from contextlib import asynccontextmanager
from typing import Dict

from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from prometheus_fastapi_instrumentator import Instrumentator
from pydantic import BaseModel, Field

from .logging_config import configure_logging
from .telemetry import setup_tracing

# ---------------------------------------------------------------------------
# Logging — must be first so all subsequent loggers use JSON format
# ---------------------------------------------------------------------------
log = configure_logging()

# ---------------------------------------------------------------------------
# Lifespan — startup / shutdown
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_tracing()
    log.info(
        "demo-service started",
        extra={
            "version": "0.1.0",
            "pool": os.getenv("POOL", "general"),
            "env": os.getenv("ENV", "production"),
        },
    )
    yield
    log.info("demo-service shutting down")


# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
app = FastAPI(
    title="demo-service",
    description=(
        "Infrastructure showcase — traces, metrics, and structured logs "
        "wired to Grafana Tempo, Prometheus, and OpenSearch."
    ),
    version="0.1.0",
    lifespan=lifespan,
)

# Instruments all routes automatically:
#   - http_requests_total (counter, by method/path/status)
#   - http_request_duration_seconds (histogram)
# Exposes them at GET /metrics for Prometheus to scrape.
Instrumentator().instrument(app).expose(app, endpoint="/metrics")

tracer = trace.get_tracer("demo-service", "0.1.0")

# ---------------------------------------------------------------------------
# In-memory item store (demo only — not persistent across restarts)
# ---------------------------------------------------------------------------
_items: Dict[int, dict] = {
    1: {"id": 1, "name": "Widget Alpha",  "value": 42,  "category": "hardware"},
    2: {"id": 2, "name": "Gadget Beta",   "value": 99,  "category": "software"},
    3: {"id": 3, "name": "Doohickey Gamma","value": 7,  "category": "hardware"},
}
_next_id = 4


class ItemCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=100)
    value: int = Field(..., ge=0)
    category: str = Field(default="general", max_length=50)


# ---------------------------------------------------------------------------
# Health probes
# ---------------------------------------------------------------------------
@app.get("/health", tags=["observability"], summary="Liveness probe")
def health():
    """Kubernetes liveness probe — returns 200 when the process is alive."""
    return {"status": "ok"}


@app.get("/readiness", tags=["observability"], summary="Readiness probe")
def readiness():
    """Kubernetes readiness probe — returns 200 when ready to serve traffic."""
    return {"status": "ready"}


# ---------------------------------------------------------------------------
# Items API
# ---------------------------------------------------------------------------
@app.get("/api/v1/items", tags=["items"], summary="List all items")
def list_items():
    """
    Returns all items in the store.

    Generates:
      - A parent trace span "list-items" (visible in Grafana Tempo)
      - A structured log line with item count (visible in OpenSearch)
      - Increments http_requests_total{path="/api/v1/items"} (visible in Grafana)
    """
    with tracer.start_as_current_span("list-items") as span:
        count = len(_items)
        span.set_attribute("items.count", count)
        log.info("listing items", extra={"count": count})
        return {"items": list(_items.values()), "total": count}


@app.post("/api/v1/items", tags=["items"], status_code=201, summary="Create an item")
def create_item(body: ItemCreate):
    """
    Creates a new item.

    Generates:
      - A trace span "create-item" with item metadata as attributes
      - A structured INFO log
    """
    global _next_id
    with tracer.start_as_current_span("create-item") as span:
        item_id = _next_id
        _next_id += 1
        item = {"id": item_id, **body.model_dump()}
        _items[item_id] = item
        span.set_attribute("item.id", item_id)
        span.set_attribute("item.category", body.category)
        log.info(
            "item created",
            extra={"item_id": item_id, "name": body.name, "category": body.category},
        )
        return item


@app.get("/api/v1/items/{item_id}", tags=["items"], summary="Get a single item")
def get_item(item_id: int):
    """
    Fetches a single item by ID.

    Generates a 404 (and an error span) when the item is not found —
    visible as an error trace in Grafana Tempo.
    """
    with tracer.start_as_current_span("get-item") as span:
        span.set_attribute("item.id", item_id)
        if item_id not in _items:
            span.set_attribute("error", True)
            span.set_attribute("http.status_code", 404)
            log.warning("item not found", extra={"item_id": item_id})
            raise HTTPException(status_code=404, detail=f"Item {item_id} not found")
        log.info("item fetched", extra={"item_id": item_id})
        return _items[item_id]


# ---------------------------------------------------------------------------
# Demo endpoints for infrastructure exploration
# ---------------------------------------------------------------------------
@app.get(
    "/api/v1/slow",
    tags=["demo"],
    summary="Slow endpoint — generates latency signal",
)
async def slow_endpoint(delay: float = 1.0):
    """
    Sleeps for `delay` seconds (capped at 10s).

    Great for:
      - Watching the `http_request_duration_seconds` histogram in Grafana
      - Seeing long-running spans in Tempo
      - Triggering latency alerts
    """
    delay = min(max(delay, 0.0), 10.0)
    with tracer.start_as_current_span("slow-operation") as span:
        span.set_attribute("delay.requested_seconds", delay)
        log.info("slow operation started", extra={"delay": delay})
        t0 = time.monotonic()
        await asyncio.sleep(delay)
        elapsed = round(time.monotonic() - t0, 3)
        span.set_attribute("delay.actual_seconds", elapsed)
        log.info("slow operation finished", extra={"elapsed_seconds": elapsed})
        return {"requested_delay": delay, "actual_elapsed": elapsed}


@app.get(
    "/api/v1/error",
    tags=["demo"],
    summary="Intentional 500 — generates error signal",
)
def trigger_error():
    """
    Always returns HTTP 500.

    Great for:
      - Seeing error spans (red) in Grafana Tempo
      - Verifying error logs land in OpenSearch with level=ERROR
      - Testing alerting rules on error rate
    """
    with tracer.start_as_current_span("intentional-error") as span:
        span.set_attribute("error", True)
        span.record_exception(RuntimeError("Demo error — this is intentional"))
        log.error(
            "intentional error triggered",
            extra={"endpoint": "/api/v1/error", "demo": True},
        )
        raise HTTPException(
            status_code=500,
            detail="Intentional error (demo endpoint — see traces in Grafana Tempo)",
        )
