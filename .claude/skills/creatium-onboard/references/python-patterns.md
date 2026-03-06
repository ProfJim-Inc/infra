# Python Patterns for the Creatium Stack

Reference implementations based on `services/demo-service/`. Copy and adapt these patterns.

---

## Dockerfile (FastAPI / Flask / Django)

```dockerfile
# ---- Build Stage ----
FROM python:3.12-slim AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy dependency files FIRST — Docker caches this layer until requirements change
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- Runtime Stage ----
FROM python:3.12-slim AS runtime

# Security: non-root user
RUN groupadd -r appuser && useradd -r -g appuser -d /app -s /sbin/nologin appuser

WORKDIR /app

# Copy installed packages from builder (not the build tools)
COPY --from=builder /install /usr/local

# Copy application code
COPY . .

RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

# Exec form ensures SIGTERM reaches Python (not a shell wrapper)
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
```

`.dockerignore`:
```
.git
.github
__pycache__
*.pyc
*.pyo
.env
.env.*
!.env.example
.DS_Store
tests/
```

---

## Health Endpoints (FastAPI)

Required paths: `/health` (liveness) and `/readiness` (readiness).

```python
from fastapi import FastAPI, status
from fastapi.responses import JSONResponse

app = FastAPI()

@app.get("/health")
def health():
    """Liveness probe — is the process alive?"""
    return {"status": "ok"}

@app.get("/readiness")
async def readiness():
    """Readiness probe — can this instance handle traffic?"""
    checks = {}

    # Check each downstream dependency:
    try:
        # Example: database check
        await db.execute("SELECT 1")
        checks["database"] = "ok"
    except Exception as e:
        checks["database"] = f"error: {e}"
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"status": "not ready", "checks": checks},
        )

    return {"status": "ready", "checks": checks}
```

If the service has no downstream dependencies, a simple 200 is fine for readiness too:
```python
@app.get("/readiness")
def readiness():
    return {"status": "ready"}
```

---

## Structured JSON Logging with OTeL Trace Injection

Copy `services/demo-service/app/logging_config.py` into your app. It provides:
- One JSON object per log line (machine-parseable by OpenSearch/Fluent Bit)
- `trace_id` / `span_id` fields on every log line while inside a span
- `extra={"key": "value"}` kwargs become top-level JSON fields

Usage:
```python
# app/main.py (top of file, before anything else)
from .logging_config import configure_logging
log = configure_logging()

# Later, in any module:
import logging
log = logging.getLogger("my-service.module-name")

log.info("item created", extra={"item_id": 42, "category": "hardware"})
# → {"timestamp":"2024-01-15T12:34:56Z","level":"INFO","logger":"my-service.module-name",
#    "message":"item created","trace_id":"abc...","span_id":"def...","item_id":42,"category":"hardware"}
```

Required packages (add to `requirements.txt`):
```
opentelemetry-sdk
opentelemetry-api
```

Environment variables:
- `LOG_LEVEL`: `DEBUG`, `INFO`, `WARNING`, `ERROR` (default: `INFO`)

---

## OTeL Distributed Tracing Setup

Copy `services/demo-service/app/telemetry.py` into your app. It:
- Sends spans to the Creatium OTeL Collector via OTLP/gRPC
- Auto-instruments all FastAPI routes (HTTP method, path, status code become span attributes)
- Falls back to console output when `OTLP_ENDPOINT=""` (local dev mode)

Usage:
```python
# app/main.py — call in the FastAPI lifespan handler
from contextlib import asynccontextmanager
from .telemetry import setup_tracing
from opentelemetry import trace

@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_tracing()   # must be called before any spans are created
    yield

app = FastAPI(lifespan=lifespan)

# Creating manual child spans in your route handlers:
tracer = trace.get_tracer("my-service", "1.0.0")

@app.get("/api/items")
def list_items():
    with tracer.start_as_current_span("list-items") as span:
        span.set_attribute("items.count", 42)
        return {"items": [...]}
```

Required packages (add to `requirements.txt`):
```
opentelemetry-sdk
opentelemetry-api
opentelemetry-exporter-otlp-proto-grpc
opentelemetry-instrumentation-fastapi
grpcio
```

Environment variables (set in `values.yaml` under `config:`):
- `OTLP_ENDPOINT`: `http://otel-collector.monitoring.svc.cluster.local:4317` (in-cluster)
- `SERVICE_NAME`: `<your-service-name>`
- `SERVICE_VERSION`: `1.0.0`
- `ENV`: `production`

---

## Prometheus Metrics (FastAPI)

The easiest path — `prometheus-fastapi-instrumentator` auto-instruments all routes:

```python
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI(...)

# Call after app is created, before first request
Instrumentator().instrument(app).expose(app, endpoint="/metrics")
```

This registers:
- `http_requests_total{handler, method, status_code}` — counter
- `http_request_duration_seconds{handler}` — histogram

Add to `requirements.txt`:
```
prometheus-fastapi-instrumentator
```

Set in `values.yaml`:
```yaml
serviceMonitor:
  enabled: true
  path: /metrics
```

---

## Environment Variable Configuration

Use `pydantic-settings` for type-safe, self-documenting config:

```python
from pydantic_settings import BaseSettings
from functools import lru_cache

class Settings(BaseSettings):
    # Service identity
    service_name: str = "my-service"
    service_version: str = "0.1.0"
    env: str = "production"
    log_level: str = "INFO"

    # OTeL (empty string disables tracing — useful for local dev)
    otlp_endpoint: str = "http://otel-collector.monitoring.svc.cluster.local:4317"

    # External dependencies (required — fail fast if not set)
    database_url: str
    redis_url: str = "redis://redis.internal:6379"

    # Secrets — injected via K8s Secrets (never committed to git)
    stripe_api_key: str = ""

    class Config:
        env_file = ".env"  # local dev only; ignored in K8s

@lru_cache
def get_settings() -> Settings:
    return Settings()
```

The non-secret settings map to `config:` in `values.yaml`.
The secret settings map to `secretRefs:` in `values.yaml` (e.g., `stripe_api_key` comes from a K8s Secret).

---

## Graceful Shutdown (FastAPI + Uvicorn)

Uvicorn handles SIGTERM natively. Use the lifespan handler for cleanup:

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    # --- Startup ---
    setup_tracing()
    app.state.db_pool = await create_pool(settings.database_url)
    log.info("service started")
    yield
    # --- Shutdown (runs on SIGTERM) ---
    await app.state.db_pool.close()
    log.info("service shutdown complete")

app = FastAPI(lifespan=lifespan)
```

The Helm chart already sets:
- `terminationGracePeriodSeconds: 15` — override in `values.yaml` for longer-running jobs
- `preStop: sleep 5` — gives the load balancer time to deregister the pod before the app stops accepting connections
