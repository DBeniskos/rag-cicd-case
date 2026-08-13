# syntax=docker/dockerfile:1
# Build context is the REPO ROOT — the job shares the index contract in app/shared with the API.
#   docker build -f app/ingest/Dockerfile -t rag-ingest .

FROM python:3.12-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

COPY app/ingest/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt


FROM python:3.12-slim AS runtime

ARG RELEASE_VERSION=0.0.0-dev
ARG GIT_SHA=unknown

LABEL org.opencontainers.image.title="rag-ingest" \
      org.opencontainers.image.description="Builds a versioned LanceDB index from the corpus" \
      org.opencontainers.image.version="${RELEASE_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}"

# The sha is recorded in every manifest, so an index can always be traced to the code that built it.
ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app/src:/app/shared \
    RAG_GIT_SHA=${GIT_SHA}

RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=10001:10001 app/ingest/src/ ./src/
COPY --chown=10001:10001 app/shared/rag_shared/ ./shared/rag_shared/

# A run-to-completion task, so no healthcheck and no exposed port: its exit code is the signal.
USER 10001:10001

ENTRYPOINT ["python", "-m", "rag_ingest"]
