"""Entrypoint for the ingestion task.

Builds one index version and writes it to stdout for the calling pipeline. Promotion is separate.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import boto3
import structlog

from rag_ingest.build import build_index
from rag_ingest.config import Settings, get_settings
from rag_ingest.corpus import CorpusError
from rag_shared.embeddings import EmbeddingError
from rag_shared.logging_config import configure_logging

log = structlog.get_logger()


def run(settings: Settings) -> str:
    if not settings.index_bucket:
        raise SystemExit("RAG_INDEX_BUCKET is required")

    s3 = boto3.client("s3", region_name=settings.aws_region)

    with tempfile.TemporaryDirectory(prefix="rag-corpus-") as workspace:
        corpus_path = Path(workspace) / Path(settings.corpus_key).name
        log.info("corpus.downloading", bucket=settings.index_bucket, key=settings.corpus_key)
        s3.download_file(settings.index_bucket, settings.corpus_key, str(corpus_path))
        manifest = build_index(settings, s3, corpus_path)

    return manifest.index_version


def main() -> int:
    settings = get_settings()
    configure_logging(settings.log_level)
    try:
        version = run(settings)
    except (CorpusError, EmbeddingError) as exc:
        # Bad inputs fail identically on retry, so retrying only spends Bedrock budget.
        log.error("ingest.failed", error=str(exc), error_type=type(exc).__name__)
        return 1

    sys.stdout.write(f"{version}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
