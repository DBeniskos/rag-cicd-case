"""FastAPI application: routes, middleware and the mapping from failure modes to status codes."""

from __future__ import annotations

import time
import uuid
from collections.abc import Awaitable, Callable
from contextlib import asynccontextmanager
from typing import TYPE_CHECKING

import structlog
from fastapi import APIRouter, FastAPI, Request, Response
from fastapi.responses import JSONResponse

from rag_api.config import NO_INDEX, Settings, get_settings
from rag_api.generation import ModelThrottledError, ModelUnavailableError, build_generator
from rag_api.retrieval import (
    EmbeddingModelMismatchError,
    IndexUnavailableError,
    build_retriever,
)
from rag_api.schemas import (
    AskRequest,
    AskResponse,
    ErrorResponse,
    HealthResponse,
    VersionResponse,
)
from rag_shared.logging_config import configure_logging

if TYPE_CHECKING:  # pragma: no cover
    from collections.abc import AsyncIterator

log = structlog.get_logger()

# The ALB polls this per task every few seconds. Logging it would be most of the log bill and
# none of the signal.
_UNLOGGED_PATHS = frozenset({"/healthz"})

router = APIRouter()


@router.get("/healthz", response_model=HealthResponse, tags=["ops"])
async def healthz() -> HealthResponse:
    """Liveness only.

    Deliberately touches neither the index nor Bedrock. If the health check called the model, a
    Bedrock outage would fail every health check, drain every target and turn a degraded service
    into no service. Index and answer quality are gated at release time, not per health poll.
    """
    return HealthResponse(status="ok")


@router.get("/version", response_model=VersionResponse, tags=["ops"])
async def version(request: Request) -> VersionResponse:
    """What is actually running. The deploy pipeline asserts on this before shifting traffic."""
    settings: Settings = request.app.state.settings
    retriever = request.app.state.retriever
    return VersionResponse(
        env=settings.env,
        release=settings.release_version,
        git_sha=settings.git_sha,
        # Read from the loaded index rather than from configuration, so this reports what is being
        # served rather than what was requested.
        index_version=retriever.index_version if retriever is not None else NO_INDEX,
        embed_model_id=settings.embed_model_id,
        text_model_id=settings.text_model_id,
    )


@router.post(
    "/ask",
    response_model=AskResponse,
    tags=["inference"],
    responses={
        429: {"model": ErrorResponse},
        502: {"model": ErrorResponse},
        503: {"model": ErrorResponse},
    },
)
async def ask(payload: AskRequest, request: Request) -> AskResponse:
    settings: Settings = request.app.state.settings
    retriever = request.app.state.retriever
    generator = request.app.state.generator

    if retriever is None:
        raise IndexUnavailableError("no index is promoted to this environment")

    started = time.perf_counter()
    passages = retriever.search(payload.question, payload.top_k or settings.top_k)
    answer = generator.generate(payload.question, passages)
    latency_ms = int((time.perf_counter() - started) * 1000)

    log.info(
        "ask.answered",
        index_version=retriever.index_version,
        passages=len(passages),
        latency_ms=latency_ms,
        input_tokens=answer.usage.input_tokens,
        output_tokens=answer.usage.output_tokens,
    )

    return AskResponse(
        answer=answer.text,
        passages=passages,
        index_version=retriever.index_version,
        text_model_id=generator.model_id,
        latency_ms=latency_ms,
        usage=answer.usage,
    )


def _error(status_code: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content=ErrorResponse(code=code, message=message).model_dump(),
    )


def create_app(settings: Settings | None = None) -> FastAPI:
    resolved = settings or get_settings()
    configure_logging(resolved.log_level)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.settings = resolved
        # A mismatch raises here, before the task reports healthy, so the deployment circuit
        # breaker rolls it back instead of serving answers grounded in the wrong vector space.
        app.state.retriever = build_retriever(resolved)
        app.state.generator = build_generator(resolved)
        log.info(
            "startup",
            env=resolved.env,
            release=resolved.release_version,
            git_sha=resolved.git_sha,
            index_version=resolved.index_version,
            index_loaded=app.state.retriever is not None,
            text_model_id=resolved.text_model_id,
        )
        yield
        log.info("shutdown")

    is_prod = resolved.env == "prod"
    app = FastAPI(
        title="rag-api",
        version=resolved.release_version,
        lifespan=lifespan,
        # No interactive docs or schema in prod: it is free attack surface on a public ALB.
        docs_url=None if is_prod else "/docs",
        redoc_url=None,
        openapi_url=None if is_prod else "/openapi.json",
    )

    @app.middleware("http")
    async def request_context(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
        structlog.contextvars.bind_contextvars(request_id=request_id)
        started = time.perf_counter()
        try:
            response = await call_next(request)
        finally:
            duration_ms = round((time.perf_counter() - started) * 1000, 2)
            if request.url.path not in _UNLOGGED_PATHS:
                log.info(
                    "http.request",
                    method=request.method,
                    path=request.url.path,
                    duration_ms=duration_ms,
                )
            structlog.contextvars.clear_contextvars()
        response.headers["x-request-id"] = request_id
        return response

    @app.exception_handler(IndexUnavailableError)
    async def _index_unavailable(_: Request, exc: IndexUnavailableError) -> JSONResponse:
        return _error(503, "index_unavailable", str(exc))

    @app.exception_handler(EmbeddingModelMismatchError)
    async def _embedding_mismatch(_: Request, exc: EmbeddingModelMismatchError) -> JSONResponse:
        return _error(503, "embedding_model_mismatch", str(exc))

    @app.exception_handler(ModelThrottledError)
    async def _model_throttled(_: Request, exc: ModelThrottledError) -> JSONResponse:
        response = _error(429, "model_throttled", str(exc))
        response.headers["retry-after"] = "1"
        return response

    @app.exception_handler(ModelUnavailableError)
    async def _model_unavailable(_: Request, exc: ModelUnavailableError) -> JSONResponse:
        return _error(502, "model_unavailable", str(exc))

    app.include_router(router)
    return app


app = create_app()
