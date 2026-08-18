"""Request and response contracts. The smoke test and eval harness both read /version."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class AskRequest(BaseModel):
    question: str = Field(min_length=1, max_length=1000)
    top_k: int | None = Field(default=None, ge=1, le=20)


class Passage(BaseModel):
    """A retrieved chunk, returned so an answer can be audited against its sources."""

    doc_id: str
    title: str
    text: str
    score: float


class TokenUsage(BaseModel):
    """Emitted per answer, so cost is observable per request rather than only on the bill."""

    input_tokens: int = 0
    output_tokens: int = 0


class AskResponse(BaseModel):
    answer: str
    passages: list[Passage]
    index_version: str
    text_model_id: str
    latency_ms: int
    usage: TokenUsage


class VersionResponse(BaseModel):
    """What is actually running. The deploy pipeline asserts against this."""

    env: str
    release: str
    git_sha: str
    index_version: str
    embed_model_id: str
    text_model_id: str


class HealthResponse(BaseModel):
    status: Literal["ok"]


class ErrorResponse(BaseModel):
    """Machine-readable so callers can distinguish causes, not just status codes."""

    code: str
    message: str
