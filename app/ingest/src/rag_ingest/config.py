"""Runtime configuration for the ingestion job.

Every value arrives as an environment variable set by the ECS task definition, so the same image
runs against dev or prod by changing the task definition rather than the image.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="RAG_", extra="ignore")

    aws_region: str = "us-east-1"
    log_level: str = "INFO"

    index_bucket: str = ""
    # Corpus lives under a separate prefix from indexes so a lifecycle rule can expire old index
    # versions without ever touching the source documents.
    corpus_key: str = "raw/movie_plots.csv"

    embed_model_id: str = "amazon.titan-embed-text-v2:0"
    embed_dimensions: int = Field(default=1024, ge=64, le=4096)
    bedrock_timeout_seconds: float = Field(default=30.0, gt=0, le=120)
    embed_concurrency: int = Field(default=8, ge=1, le=32)

    title_column: str = "Title"
    text_column: str = "Plot"
    # A few hundred documents is enough to exercise the pipeline; the corpus is not the point.
    doc_limit: int = Field(default=400, ge=1, le=100_000)

    chunk_max_chars: int = Field(default=1200, ge=200, le=8000)
    chunk_overlap_chars: int = Field(default=150, ge=0, le=2000)

    git_sha: str = "unknown"


@lru_cache
def get_settings() -> Settings:
    return Settings()
