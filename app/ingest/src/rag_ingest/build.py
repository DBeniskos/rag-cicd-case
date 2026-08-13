"""Build one immutable index version and publish it.

The job deliberately stops short of making the new index live. Building and promoting are separate
steps because promotion has to be gated on evaluation results, and because a promotion that is
just a pointer flip can be reversed in seconds without rebuilding anything.
"""

from __future__ import annotations

import re
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import lancedb
import pyarrow as pa
import structlog

from rag_ingest.chunking import Chunk, chunk_documents
from rag_ingest.config import Settings
from rag_ingest.corpus import corpus_hash, load_documents
from rag_shared.embeddings import BedrockEmbedder, build_bedrock_client
from rag_shared.manifest import MANIFEST_FILENAME, TABLE_NAME, IndexManifest, index_prefix

log = structlog.get_logger()

_VERSION_PREFIX = re.compile(r"^indexes/v(\d+)-")


def next_index_version(s3: Any, bucket: str, git_sha: str) -> str:
    """Allocate the next version number.

    Derived from what is already published rather than from a counter held elsewhere, so there is
    no second source of truth to drift. The git sha is appended to make the provenance of an index
    readable straight from its name.
    """
    highest = 0
    for page in s3.get_paginator("list_objects_v2").paginate(
        Bucket=bucket, Prefix="indexes/", Delimiter="/"
    ):
        for entry in page.get("CommonPrefixes", []):
            match = _VERSION_PREFIX.match(entry["Prefix"])
            if match:
                highest = max(highest, int(match.group(1)))
    return f"v{highest + 1}-{git_sha}"


def write_table(directory: Path, chunks: list[Chunk], vectors: list[list[float]], dims: int) -> None:
    schema = pa.schema(
        [
            pa.field("doc_id", pa.string()),
            pa.field("title", pa.string()),
            pa.field("text", pa.string()),
            pa.field("ordinal", pa.int32()),
            pa.field("vector", pa.list_(pa.float32(), dims)),
        ]
    )
    rows = [
        {
            "doc_id": chunk.doc_id,
            "title": chunk.title,
            "text": chunk.text,
            "ordinal": chunk.ordinal,
            "vector": vector,
        }
        for chunk, vector in zip(chunks, vectors, strict=True)
    ]
    lancedb.connect(directory).create_table(TABLE_NAME, data=rows, schema=schema)


def upload_directory(s3: Any, directory: Path, bucket: str, prefix: str) -> int:
    """Publish the index, manifest last.

    Ordering matters: a reader that finds the manifest can rely on the data already being there.
    The reverse order would expose a window where an index looks published but is incomplete.
    """
    manifest = directory / MANIFEST_FILENAME
    payload = [p for p in sorted(directory.rglob("*")) if p.is_file() and p != manifest]
    payload.append(manifest)

    for path in payload:
        key = f"{prefix}{path.relative_to(directory).as_posix()}"
        s3.upload_file(str(path), bucket, key)
    return len(payload)


def build_index(settings: Settings, s3: Any, corpus_path: Path) -> IndexManifest:
    documents = load_documents(
        corpus_path,
        title_column=settings.title_column,
        text_column=settings.text_column,
        limit=settings.doc_limit,
    )
    chunks = chunk_documents(documents, settings.chunk_max_chars, settings.chunk_overlap_chars)
    log.info("corpus.chunked", documents=len(documents), chunks=len(chunks))

    embedder = BedrockEmbedder(
        client=build_bedrock_client(settings.aws_region, settings.bedrock_timeout_seconds),
        model_id=settings.embed_model_id,
        dimensions=settings.embed_dimensions,
        max_workers=settings.embed_concurrency,
    )
    vectors = embedder.embed_many([chunk.text for chunk in chunks])
    log.info("corpus.embedded", vectors=len(vectors), model_id=settings.embed_model_id)

    version = next_index_version(s3, settings.index_bucket, settings.git_sha)
    manifest = IndexManifest(
        index_version=version,
        embed_model_id=settings.embed_model_id,
        embed_dimensions=settings.embed_dimensions,
        corpus_hash=corpus_hash(corpus_path),
        doc_count=len(documents),
        chunk_count=len(chunks),
        git_sha=settings.git_sha,
        built_at=datetime.now(UTC),
    )

    with tempfile.TemporaryDirectory(prefix="rag-index-") as workspace:
        directory = Path(workspace)
        write_table(directory, chunks, vectors, settings.embed_dimensions)
        manifest.write(directory / MANIFEST_FILENAME)
        uploaded = upload_directory(s3, directory, settings.index_bucket, index_prefix(version))

    log.info(
        "index.published",
        index_version=version,
        objects=uploaded,
        bucket=settings.index_bucket,
        chunk_count=manifest.chunk_count,
    )
    return manifest
