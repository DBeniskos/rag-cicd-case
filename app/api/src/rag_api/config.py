"""Runtime configuration.

Every value arrives as an environment variable set by the ECS task definition. Nothing is read
from a file at runtime and nothing is baked into the image except the build stamps, so the same
image digest is promoted unchanged from dev to prod.
"""

from __future__ import annotations

from functools import lru_cache
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

# Sentinel for "no index has been promoted to this environment yet" — a legitimate state for a
# freshly provisioned environment, distinct from "the index failed to load".
NO_INDEX = "none"


class Settings(BaseSettings):
    """Environment-driven settings, prefixed ``RAG_``."""

    model_config = SettingsConfigDict(env_prefix="RAG_", extra="ignore")

    env: Literal["local", "dev", "prod"] = "local"
    aws_region: str = "us-east-1"
    log_level: str = "INFO"

    # Stamped into the image at build time. /version surfaces these so a deploy can be *proven*
    # rather than assumed — the smoke test asserts the running release equals the released one.
    release_version: str = "0.0.0-dev"
    git_sha: str = "unknown"

    # Injected from SSM by the task definition. A pointer flip plus a task restart is the whole
    # index rollback mechanism.
    index_bucket: str = ""
    index_version: str = NO_INDEX

    # When set, the live index version is read from this SSM parameter at startup instead of from
    # index_version. The parameter is what promotion and rollback write, so reading it here is what
    # makes a pointer flip reach the service — otherwise the task definition would have to be
    # rewritten for every promotion, and rollback would stop being a one-line operation.
    active_index_parameter: str = ""

    embed_model_id: str = "amazon.titan-embed-text-v2:0"
    # Inference profile rather than a bare model id: newer Anthropic models are only invokable
    # through one, and the profile is what routes the call across regions.
    text_model_id: str = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

    top_k: int = Field(default=4, ge=1, le=20)
    # Caps the blast radius of a runaway prompt on the bill, not just on latency.
    max_output_tokens: int = Field(default=512, ge=1, le=4096)
    max_question_chars: int = Field(default=1000, ge=1, le=10_000)
    bedrock_timeout_seconds: float = Field(default=20.0, gt=0, le=60)


@lru_cache
def get_settings() -> Settings:
    return Settings()
