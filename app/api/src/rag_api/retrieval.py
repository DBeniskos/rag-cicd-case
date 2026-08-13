"""Retrieval: loading the promoted index and querying it.

Swapping LanceDB-on-S3 for OpenSearch Serverless or pgvector means a new class in this module and
one line in ``build_retriever`` — the module boundary is the seam, which is why the trade-off is
written down in an ADR rather than hard-coded as the winner.

The index is copied to local disk at startup rather than queried over S3. That trades a slower
start for predictable query latency (the p95 release gate measures the query path, not S3), and it
puts manifest validation before the task ever reports healthy.
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any

import boto3
import lancedb
import structlog
from botocore.exceptions import BotoCoreError, ClientError

from rag_api.config import NO_INDEX, Settings
from rag_api.schemas import Passage
from rag_shared.embeddings import BedrockEmbedder, build_bedrock_client
from rag_shared.manifest import MANIFEST_FILENAME, TABLE_NAME, IndexManifest, index_prefix

log = structlog.get_logger()


class IndexUnavailableError(RuntimeError):
    """The promoted index could not be loaded or served."""


class EmbeddingModelMismatchError(RuntimeError):
    """The index was built with a different embedding model than the one this service queries with.

    Fatal on purpose: vectors from two different embedding models share a space only by accident,
    so retrieval would silently return plausible nonsense. Failing to start turns a silent quality
    incident into a loud deployment failure that the circuit breaker rolls back.
    """


class LanceRetriever:
    """Queries a local LanceDB table with a Bedrock-embedded question.

    At this corpus size LanceDB scans exhaustively, which is exact and fast enough. An ANN index
    becomes worthwhile in the tens of thousands of vectors; adding one before then would trade
    recall for a speed-up nobody needs.
    """

    def __init__(self, table: Any, embedder: BedrockEmbedder, manifest: IndexManifest) -> None:
        self._table = table
        self._embedder = embedder
        self.manifest = manifest
        self.index_version = manifest.index_version

    def search(self, question: str, top_k: int) -> list[Passage]:
        vector = self._embedder.embed_one(question)
        try:
            rows = self._table.search(vector).distance_type("cosine").limit(top_k).to_list()
        except Exception as exc:  # lancedb surfaces backend failures as assorted exception types
            log.error("index.search_failed", index_version=self.index_version, error=str(exc))
            raise IndexUnavailableError("vector search failed") from exc

        return [
            Passage(
                doc_id=row["doc_id"],
                title=row["title"],
                text=row["text"],
                # LanceDB returns cosine *distance*; the API reports similarity.
                score=round(1.0 - float(row["_distance"]), 4),
            )
            for row in rows
        ]


def download_index(s3: Any, bucket: str, index_version: str, root: Path) -> Path:
    """Copy one immutable index prefix to local disk."""
    prefix = index_prefix(index_version)
    destination = (root / index_version).resolve()
    destination.mkdir(parents=True, exist_ok=True)

    downloaded = 0
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith("/"):
                continue
            target = (destination / key[len(prefix) :]).resolve()
            # The bucket is ours, but a key containing '..' would still escape the download
            # directory, so the join is validated rather than trusted.
            if not target.is_relative_to(destination):
                raise IndexUnavailableError(f"refusing key outside index directory: {key}")
            target.parent.mkdir(parents=True, exist_ok=True)
            s3.download_file(bucket, key, str(target))
            downloaded += 1

    if downloaded == 0:
        raise IndexUnavailableError(f"no objects under s3://{bucket}/{prefix}")

    log.info("index.downloaded", index_version=index_version, objects=downloaded)
    return destination


def resolve_index_version(settings: Settings, ssm: Any) -> str:
    """Determine which index this task should serve.

    The SSM parameter wins when configured, because that is what the promotion pipeline writes.
    A failure to read it is fatal rather than a silent fall back to the baked-in value: serving
    the wrong index quietly is precisely the failure this design exists to prevent.
    """
    if not settings.active_index_parameter:
        return settings.index_version

    try:
        response = ssm.get_parameter(Name=settings.active_index_parameter)
    except (BotoCoreError, ClientError) as exc:
        raise IndexUnavailableError(f"could not read {settings.active_index_parameter}") from exc

    version = response["Parameter"]["Value"]
    log.info("index.pointer_resolved", parameter=settings.active_index_parameter, version=version)
    return version


def build_retriever(settings: Settings) -> LanceRetriever | None:
    """Load the index this environment currently points at.

    Returns ``None`` when no index has been promoted yet. That is a normal state for a freshly
    provisioned environment: the service starts, reports healthy to the load balancer, and refuses
    ``/ask`` with a machine-readable error. Liveness and readiness are deliberately separate — an
    unpromoted index must not deregister a task that is otherwise fine.

    Every other failure raises, because a task that cannot serve its purpose should not report
    healthy; ECS replaces it and the circuit breaker rolls the deployment back.
    """
    if not settings.index_bucket:
        log.warning("index.no_bucket_configured")
        return None

    index_version = resolve_index_version(
        settings, boto3.client("ssm", region_name=settings.aws_region)
    )

    if index_version == NO_INDEX:
        log.warning("index.not_promoted", index_bucket=settings.index_bucket)
        return None

    s3 = boto3.client("s3", region_name=settings.aws_region)
    cache_root = Path(tempfile.gettempdir()) / "rag-index"
    local_dir = download_index(s3, settings.index_bucket, index_version, cache_root)

    manifest_path = local_dir / MANIFEST_FILENAME
    try:
        manifest = IndexManifest.read(manifest_path)
    except (OSError, ValueError) as exc:
        raise IndexUnavailableError(f"unreadable manifest at {manifest_path}") from exc

    if manifest.embed_model_id != settings.embed_model_id:
        raise EmbeddingModelMismatchError(
            f"index {manifest.index_version} was built with {manifest.embed_model_id}, "
            f"but this service queries with {settings.embed_model_id}"
        )

    try:
        table = lancedb.connect(local_dir).open_table(TABLE_NAME)
    except Exception as exc:  # lancedb surfaces backend failures as assorted exception types
        raise IndexUnavailableError(f"could not open table '{TABLE_NAME}'") from exc

    log.info(
        "index.loaded",
        index_version=manifest.index_version,
        chunk_count=manifest.chunk_count,
        doc_count=manifest.doc_count,
        embed_model_id=manifest.embed_model_id,
        corpus_hash=manifest.corpus_hash,
    )
    return LanceRetriever(
        table=table,
        embedder=BedrockEmbedder(
            client=build_bedrock_client(settings.aws_region, settings.bedrock_timeout_seconds),
            model_id=settings.embed_model_id,
            dimensions=manifest.embed_dimensions,
        ),
        manifest=manifest,
    )
