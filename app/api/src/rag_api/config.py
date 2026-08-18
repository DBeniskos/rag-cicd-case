"""Runtime configuration, supplied as RAG_* environment variables by the task definition."""

from __future__ import annotations

from functools import lru_cache
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

# Distinguishes "nothing promoted yet" from "the index failed to load".
NO_INDEX = "none"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="RAG_", extra="ignore")

    env: Literal["local", "dev", "prod"] = "local"
    aws_region: str = "us-east-1"
    log_level: str = "INFO"

    # Stamped in at build time. /version surfaces these so a deploy can be proven, not assumed.
    release_version: str = "0.0.0-dev"
    git_sha: str = "unknown"

    index_bucket: str = ""
    index_version: str = NO_INDEX

    # Promotion and rollback write this parameter, so reading it at startup is what lets a pointer
    # flip reach the service without rewriting the task definition.
    active_index_parameter: str = ""

    embed_model_id: str = "amazon.titan-embed-text-v2:0"
    # Cross-region inference profile id, not a bare model id. See docs/decisions.md.
    text_model_id: str = "us.amazon.nova-lite-v1:0"

    # Injected by the ECS agent from Secrets Manager. Empty disables auth, which is what local
    # runs and unit tests use — deployed environments always have it set.
    api_key: str = ""

    # Interactive docs publish every route and payload shape. Enabled here so each environment is
    # demonstrable from a browser; set false to keep a public prod endpoint opaque.
    docs_enabled: bool = True

    # Comma-separated "label=url" targets offered in the docs Servers dropdown, so one console can
    # drive every environment. Empty means the page can only call the host it was loaded from.
    docs_servers: str = ""

    @property
    def docs_server_list(self) -> list[dict[str, str]]:
        servers: list[dict[str, str]] = []
        for entry in self.docs_servers.split(","):
            label, _, url = entry.strip().partition("=")
            if url:
                servers.append({"url": url, "description": label})
        return servers

    top_k: int = Field(default=4, ge=1, le=20)
    # Caps the cost of a runaway prompt, not just its latency.
    max_output_tokens: int = Field(default=512, ge=1, le=4096)
    max_question_chars: int = Field(default=1000, ge=1, le=10_000)
    bedrock_timeout_seconds: float = Field(default=20.0, gt=0, le=60)


@lru_cache
def get_settings() -> Settings:
    return Settings()
