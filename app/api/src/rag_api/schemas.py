"""Request and response contracts. The smoke test and eval harness both read /healthz."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class AskRequest(BaseModel):
    question: str = Field(min_length=1, max_length=1000)
    top_k: int | None = Field(default=None, ge=1, le=20)

    # Names the document, because the sample corpus is small enough that a vague question retrieves
    # the right passage too weakly and the model correctly refuses.
    model_config = {
        "json_schema_extra": {
            "examples": [
                {"question": "What happens to the understudy in The Understudy?", "top_k": 4}
            ]
        }
    }


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


class HealthResponse(BaseModel):
    """Liveness plus what is actually running.

    One unauthenticated GET rather than a separate /version: the ALB health check, the smoke test
    and the eval harness all need the same facts, and two routes carrying release identity is two
    routes that can disagree.
    """

    status: Literal["ok"]
    env: str
    release: str
    git_sha: str
    index_version: str
    embed_model_id: str
    text_model_id: str

    model_config = {
        "json_schema_extra": {
            "examples": [
                {
                    "status": "ok",
                    "env": "prod",
                    "release": "v0.9.0",
                    "git_sha": "7b23b5f",
                    "index_version": "v1-f2e9a6b",
                    "embed_model_id": "amazon.titan-embed-text-v2:0",
                    "text_model_id": "us.amazon.nova-lite-v1:0",
                }
            ]
        }
    }


class ErrorResponse(BaseModel):
    """Machine-readable so callers can distinguish causes, not just status codes."""

    code: str
    message: str
