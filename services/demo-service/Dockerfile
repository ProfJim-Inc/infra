# =============================================================================
# demo-service — multi-stage build
#
# Stage 1 (deps): installs Python packages into /root/.local
# Stage 2 (runtime): minimal image, non-root user, only runtime deps
# =============================================================================

# --- Stage 1: dependency installation ---
FROM python:3.12-slim AS deps

WORKDIR /build

# Install deps first — layer is cached as long as requirements.txt is unchanged
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# --- Stage 2: runtime image ---
FROM python:3.12-slim AS runtime

WORKDIR /app

# Non-root user for security
RUN groupadd -r app && useradd -r -g app --home /app app

# Copy installed packages into system Python path (no PATH tricks needed)
COPY --from=deps /install /usr/local

# Copy application source
COPY app/ ./app/

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN chown -R app:app /app
USER app

EXPOSE 8000

# 2 workers is right for a CPU-bound Python service on 2 vCPUs.
# Adjust --workers via CMD override in values.yaml if needed.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
