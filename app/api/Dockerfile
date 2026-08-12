# syntax=docker/dockerfile:1
# Build context is the REPO ROOT, because the API imports the shared ingest/API contract in
# app/shared. .dockerignore is what keeps Terraform state, docs and the venv out of the context.
#   docker build -f app/api/Dockerfile -t rag-api .

FROM python:3.12-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

COPY app/api/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt


FROM python:3.12-slim AS runtime

ARG RELEASE_VERSION=0.0.0-dev
ARG GIT_SHA=unknown

LABEL org.opencontainers.image.title="rag-api" \
      org.opencontainers.image.description="RAG inference API — retrieves context and answers via Amazon Bedrock" \
      org.opencontainers.image.version="${RELEASE_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}"

# Build stamps become runtime settings, which is how /version can prove which release is serving.
ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app/src:/app/shared \
    RAG_RELEASE_VERSION=${RELEASE_VERSION} \
    RAG_GIT_SHA=${GIT_SHA}

RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=10001:10001 app/api/src/ ./src/
COPY --chown=10001:10001 app/shared/rag_shared/ ./shared/rag_shared/

# Numeric UID so the ECS task definition can assert a non-root user without resolving /etc/passwd.
USER 10001:10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).status == 200 else 1)"]

# Access logging is handled by the structured-logging middleware; uvicorn's would only duplicate
# it at CloudWatch ingestion prices.
CMD ["uvicorn", "rag_api.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
