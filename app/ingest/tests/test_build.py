from __future__ import annotations

import csv
from pathlib import Path
from typing import Any

import lancedb
import pytest

from rag_ingest.build import build_index, next_index_version, upload_directory, write_table
from rag_ingest.chunking import Chunk
from rag_ingest.config import Settings
from rag_shared.manifest import MANIFEST_FILENAME, TABLE_NAME

# Above the floor enforced by Settings.embed_dimensions; the real Titan default is 1024.
DIMENSIONS = 256
PLOT = "A long enough plot to survive the minimum length filter. " * 5


class FakeS3:
    def __init__(self, prefixes: list[str] | None = None) -> None:
        self._prefixes = prefixes or []
        self.uploaded: list[str] = []

    def get_paginator(self, name: str) -> Any:
        prefixes = self._prefixes

        class _Paginator:
            def paginate(self, **kwargs: Any) -> Any:
                yield {"CommonPrefixes": [{"Prefix": p} for p in prefixes]}

        return _Paginator()

    def upload_file(self, filename: str, bucket: str, key: str) -> None:
        self.uploaded.append(key)


class FakeEmbedder:
    def __init__(self) -> None:
        self.model_id = "fake"
        self.dimensions = DIMENSIONS

    def embed_many(self, texts: list[str]) -> list[list[float]]:
        return [[float(len(t) % 7)] + [0.0] * (DIMENSIONS - 1) for t in texts]


def test_next_index_version_starts_at_one_when_empty() -> None:
    assert next_index_version(FakeS3([]), "bucket", "abc1234") == "v1-abc1234"


def test_next_index_version_continues_from_the_highest_published() -> None:
    """Derived from what exists, so there is no counter elsewhere to drift out of sync."""
    s3 = FakeS3(["indexes/v1-aaa/", "indexes/v9-bbb/", "indexes/v3-ccc/"])

    assert next_index_version(s3, "bucket", "abc1234") == "v10-abc1234"


def test_next_index_version_ignores_unrecognised_prefixes() -> None:
    s3 = FakeS3(["indexes/scratch/", "indexes/v2-aaa/"])

    assert next_index_version(s3, "bucket", "sha") == "v3-sha"


def test_write_table_is_readable_by_lancedb(tmp_path: Path) -> None:
    chunks = [Chunk(doc_id="d1", title="T", text="body one", ordinal=0)]
    vector = [1.0] + [0.0] * (DIMENSIONS - 1)

    write_table(tmp_path, chunks, [vector], DIMENSIONS)

    table = lancedb.connect(tmp_path).open_table(TABLE_NAME)
    rows = table.search(vector).limit(1).to_list()
    assert rows[0]["doc_id"] == "d1"
    assert rows[0]["text"] == "body one"


def test_write_table_rejects_mismatched_vector_count(tmp_path: Path) -> None:
    """Chunks and vectors are zipped by position; a length mismatch must not pass silently."""
    chunks = [Chunk(doc_id="d1", title="T", text="a", ordinal=0)]

    with pytest.raises(ValueError, match=r"argument 2 is shorter|zip"):
        write_table(tmp_path, chunks, [], DIMENSIONS)


def test_upload_directory_publishes_the_manifest_last(tmp_path: Path) -> None:
    """A reader that sees the manifest must be able to rely on the data already being there."""
    (tmp_path / "data").mkdir()
    (tmp_path / "data" / "part.bin").write_text("x", encoding="utf-8")
    (tmp_path / MANIFEST_FILENAME).write_text("{}", encoding="utf-8")
    s3 = FakeS3()

    count = upload_directory(s3, tmp_path, "bucket", "indexes/v1-abc/")

    assert count == 2
    assert s3.uploaded[-1] == f"indexes/v1-abc/{MANIFEST_FILENAME}"
    assert "indexes/v1-abc/data/part.bin" in s3.uploaded


def test_build_index_produces_a_consistent_manifest(tmp_path: Path, monkeypatch) -> None:
    corpus = tmp_path / "corpus.csv"
    with corpus.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["Title", "Plot"])
        writer.writeheader()
        writer.writerows([{"Title": f"Film {i}", "Plot": PLOT} for i in range(3)])

    monkeypatch.setattr("rag_ingest.build.build_bedrock_client", lambda *a, **k: object())
    monkeypatch.setattr("rag_ingest.build.BedrockEmbedder", lambda **kwargs: FakeEmbedder())

    settings = Settings(
        index_bucket="bucket",
        embed_dimensions=DIMENSIONS,
        doc_limit=10,
        git_sha="abc1234",
    )
    s3 = FakeS3([])

    manifest = build_index(settings, s3, corpus)

    assert manifest.index_version == "v1-abc1234"
    assert manifest.doc_count == 3
    assert manifest.chunk_count >= 3
    assert manifest.corpus_hash.startswith("sha256:")
    # The API refuses to start if these disagree with its own settings, so they must be recorded.
    assert manifest.embed_model_id == settings.embed_model_id
    assert manifest.embed_dimensions == DIMENSIONS
    assert any(key.endswith(MANIFEST_FILENAME) for key in s3.uploaded)
