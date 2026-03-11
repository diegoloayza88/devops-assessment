# ──────────────────────────────────────────────────────────────────────────────
# Stage 1 – build / dependency resolution
# ──────────────────────────────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /build

# Install build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

# Install into an isolated prefix to copy only the site-packages
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# ──────────────────────────────────────────────────────────────────────────────
# Stage 2 – lean runtime image
# ──────────────────────────────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

LABEL maintainer="diegoyloayza@gmail.com"
LABEL org.opencontainers.image.title="qa-service"
LABEL org.opencontainers.image.description="AI Q&A FastAPI service backed by vLLM"

# Non-root user for security
RUN groupadd --gid 1001 appgroup && \
    useradd  --uid 1001 --gid appgroup --no-create-home appuser

WORKDIR /app

# Copy installed packages from builder stage
COPY --from=builder /install /usr/local

# Copy application source
COPY main.py .

# Ensure the process has no write access outside /tmp
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8080

# Uvicorn – 2 workers per replica; tune via env if needed
CMD ["uvicorn", "main:app", \
     "--host", "0.0.0.0", \
     "--port", "8080", \
     "--workers", "2", \
     "--log-level", "info", \
     "--access-log"]
