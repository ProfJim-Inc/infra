# Python Service Patterns for Kubernetes

## Dockerfile Template (FastAPI / Flask / Django)

```dockerfile
# ---- Build Stage ----
FROM python:3.12-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy dependency files first for layer caching
COPY requirements.txt .
# Or if using poetry:
# COPY pyproject.toml poetry.lock ./
# RUN pip install poetry && poetry export -f requirements.txt -o requirements.txt

RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- Runtime Stage ----
FROM python:3.12-slim AS runtime

# Security: run as non-root
RUN groupadd -r appuser && useradd -r -g appuser -d /app -s /sbin/nologin appuser

WORKDIR /app

# Copy only the installed packages from builder
COPY --from=builder /install /usr/local

# Copy application code
COPY . .

# Set ownership
RUN chown -R appuser:appuser /app

USER appuser

# Expose the application port
EXPOSE 8000

# Health check at container level (K8s probes are primary, this is backup)
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

# Use exec form so signals (SIGTERM) reach the Python process directly
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4"]
```

### Key notes:
- Use `--workers` based on CPU requests (2x CPU cores is a good starting point)
- For Gunicorn + Uvicorn: `CMD ["gunicorn", "app.main:app", "-w", "4", "-k", "uvicorn.workers.UvicornWorker", "--bind", "0.0.0.0:8000"]`
- For Django: `CMD ["gunicorn", "myproject.wsgi:application", "--bind", "0.0.0.0:8000"]`

## Health Check Patterns

### FastAPI
```python
from fastapi import FastAPI, status
from fastapi.responses import JSONResponse
import asyncpg  # or whatever your DB client is

app = FastAPI()

@app.get("/health")
async def health():
    """Liveness probe — is the process alive and responsive?"""
    return {"status": "healthy"}

@app.get("/ready")
async def ready():
    """Readiness probe — can this instance handle traffic?"""
    checks = {}

    # Check database connectivity
    try:
        pool = app.state.db_pool
        async with pool.acquire() as conn:
            await conn.fetchval("SELECT 1")
        checks["database"] = "ok"
    except Exception as e:
        checks["database"] = f"error: {str(e)}"
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"status": "not ready", "checks": checks}
        )

    # Check Redis connectivity
    try:
        redis = app.state.redis
        await redis.ping()
        checks["redis"] = "ok"
    except Exception as e:
        checks["redis"] = f"error: {str(e)}"
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"status": "not ready", "checks": checks}
        )

    return {"status": "ready", "checks": checks}
```

### Flask
```python
from flask import Flask, jsonify

app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify(status="healthy"), 200

@app.route("/ready")
def ready():
    try:
        db.session.execute("SELECT 1")
        return jsonify(status="ready"), 200
    except Exception as e:
        return jsonify(status="not ready", error=str(e)), 503
```

## Graceful Shutdown

### FastAPI / Uvicorn
Uvicorn handles SIGTERM natively — it stops accepting new connections and waits for in-flight requests to complete. Configure the grace period:

```python
# In your FastAPI app
from contextlib import asynccontextmanager
import signal

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    app.state.db_pool = await create_db_pool()
    app.state.redis = await create_redis_connection()
    yield
    # Shutdown (runs on SIGTERM)
    await app.state.db_pool.close()
    await app.state.redis.close()
    print("Graceful shutdown complete")

app = FastAPI(lifespan=lifespan)
```

In Kubernetes deployment:
```yaml
spec:
  terminationGracePeriodSeconds: 30  # match your app's drain time
  containers:
    - name: app
      lifecycle:
        preStop:
          exec:
            command: ["sleep", "5"]  # allow load balancer to deregister
```

## Structured Logging

```python
import structlog
import logging

# Configure structlog for JSON output
structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer()
    ],
    wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
)

logger = structlog.get_logger()

# Usage
logger.info("request_processed",
    method="GET",
    path="/api/users",
    duration_ms=42,
    status_code=200,
    request_id="abc-123"
)
# Output: {"event": "request_processed", "method": "GET", "path": "/api/users", "duration_ms": 42, "status_code": 200, "request_id": "abc-123", "level": "info", "timestamp": "2026-02-26T10:30:00Z"}
```

## Prometheus Metrics (Optional)

```python
from prometheus_client import Counter, Histogram, generate_latest
from fastapi import Request, Response

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status_code"]
)

REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["method", "endpoint"]
)

@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    import time
    start = time.time()
    response = await call_next(request)
    duration = time.time() - start

    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.url.path,
        status_code=response.status_code
    ).inc()

    REQUEST_DURATION.labels(
        method=request.method,
        endpoint=request.url.path
    ).observe(duration)

    return response

@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type="text/plain")
```

## Environment Configuration Pattern

```python
from pydantic_settings import BaseSettings
from functools import lru_cache

class Settings(BaseSettings):
    """Application configuration loaded from environment variables.

    In Kubernetes, these come from ConfigMaps and Secrets.
    """
    # App
    app_name: str = "my-service"
    debug: bool = False
    port: int = 8000

    # Database
    database_url: str  # Required — will fail fast if not set
    database_pool_size: int = 5

    # Redis
    redis_url: str = "redis://localhost:6379"

    # External APIs
    stripe_api_key: str = ""  # Injected via K8s Secret

    class Config:
        env_file = ".env"  # For local development only

@lru_cache
def get_settings() -> Settings:
    return Settings()
```
