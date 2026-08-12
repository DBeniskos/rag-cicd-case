from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import lancedb
import pyarrow as pa
import pytest

from rag_api import retrieval
from rag_api.config import Settings
from rag_api.retrieval import (
    EmbeddingModelMismatchError,
    IndexUnavailableError,
    LanceRetriever,
    download_index,
)
from rag_shared.manifest import MANIFEST_FILENAME, TABLE_NAME, IndexManifest

DIMENSIONS = 4


def make_manifest(**overrides: Any) -> IndexManifest:
    values: dict[str, Any] = {
        "index_version": "v3-abc1234",
        "embed_model_id": "amazon.titan-embed-text-v2:0",
        "embed_dimensions": DIMENSIONS,
        "corpus_hash": "sha256:deadbeef",
        "doc_count": 3,
        "chunk_count": 3,
        "git_sha": "abc1234",
        "built_at": datetime(2026, 1, 1, tzinfo=UTC),
    }
    values.update(overrides)
    return IndexManifest(**values)


def make_table(directory: Path) -> Any:
    """A real LanceDB table — the vector search path is exercised, not mocked."""
    schema = pa.schema(
        [
            pa.field("doc_id", pa.string()),
            pa.field("title", pa.string()),
            pa.field("text", pa.string()),
            pa.field("vector", pa.list_(pa.float32(), DIMENSIONS)),
        ]
    )
    rows = [
        {"doc_id": "d1", "title": "Alpha", "text": "alpha text", "vector": [1.0, 0.0, 0.0, 0.0]},
        {"doc_id": "d2", "title": "Beta", "text": "beta text", "vector": [0.0, 1.0, 0.0, 0.0]},
        {"doc_id": "d3", "title": "Gamma", "text": "gamma text", "vector": [0.0, 0.0, 1.0, 0.0]},
    ]
    return lancedb.connect(directory).create_table(TABLE_NAME, data=rows, schema=schema)


class FakeEmbedder:
    def __init__(self, vector: list[float]) -> None:
        self.model_id = "fake-embed"
        self.dimensions = len(vector)
        self._vector = vector

    def embed_one(self, text: str) -> list[float]:
        return self._vector


class FakeS3:
    def __init__(self, keys: list[str]) -> None:
        self._keys = keys
        self.downloaded: list[str] = []

    def get_paginator(self, name: str) -> Any:
        keys = self._keys

        class _Paginator:
            def paginate(self, **kwargs: Any) -> Any:
                yield {"Contents": [{"Key": key} for key in keys]}

        return _Paginator()

    def download_file(self, bucket: str, key: str, filename: str) -> None:
        Path(filename).write_text("payload", encoding="utf-8")
        self.downloaded.append(key)


def test_search_returns_nearest_passage_first(tmp_path: Path) -> None:
    retriever = LanceRetriever(
        make_table(tmp_path), FakeEmbedder([1.0, 0.0, 0.0, 0.0]), make_manifest()
    )

    passages = retriever.search("anything", top_k=2)

    assert len(passages) == 2
    assert passages[0].doc_id == "d1"
    assert passages[0].title == "Alpha"
    # Cosine distance 0 against an identical vector, reported as similarity 1.
    assert passages[0].score == pytest.approx(1.0, abs=1e-3)


def test_search_honours_top_k(tmp_path: Path) -> None:
    retriever = LanceRetriever(
        make_table(tmp_path), FakeEmbedder([1.0, 0.0, 0.0, 0.0]), make_manifest()
    )

    assert len(retriever.search("anything", top_k=1)) == 1
    assert len(retriever.search("anything", top_k=3)) == 3


def test_search_wraps_backend_failure(tmp_path: Path) -> None:
    class ExplodingTable:
        def search(self, vector: list[float]) -> Any:
            raise RuntimeError("backend gone")

    retriever = LanceRetriever(
        ExplodingTable(), FakeEmbedder([1.0, 0.0, 0.0, 0.0]), make_manifest()
    )

    with pytest.raises(IndexUnavailableError):
        retriever.search("anything", top_k=1)


def test_download_index_copies_every_object(tmp_path: Path) -> None:
    s3 = FakeS3(["indexes/v1-abc/manifest.json", "indexes/v1-abc/passages.lance/data.bin"])

    destination = download_index(s3, "bucket", "v1-abc", tmp_path)

    assert (destination / "manifest.json").exists()
    assert (destination / "passages.lance" / "data.bin").exists()
    assert len(s3.downloaded) == 2


def test_download_index_rejects_keys_escaping_the_directory(tmp_path: Path) -> None:
    """A key containing '..' must not be able to write outside the index directory."""
    s3 = FakeS3(["indexes/v1-abc/../../etc/evil.conf"])

    with pytest.raises(IndexUnavailableError, match="outside index directory"):
        download_index(s3, "bucket", "v1-abc", tmp_path)

    assert s3.downloaded == []


def test_download_index_fails_when_prefix_is_empty(tmp_path: Path) -> None:
    with pytest.raises(IndexUnavailableError, match="no objects"):
        download_index(FakeS3([]), "bucket", "v1-abc", tmp_path)


def test_build_retriever_returns_none_when_no_index_promoted() -> None:
    settings = Settings(index_bucket="", index_version="none")

    assert retrieval.build_retriever(settings) is None


def test_build_retriever_rejects_embedding_model_mismatch(tmp_path: Path, monkeypatch) -> None:
    """The drift guard: an index built by another embedding model must stop the task starting."""
    make_manifest(embed_model_id="amazon.titan-embed-text-v1").write(tmp_path / MANIFEST_FILENAME)
    monkeypatch.setattr(retrieval.boto3, "client", lambda *a, **k: object())
    monkeypatch.setattr(retrieval, "download_index", lambda *a, **k: tmp_path)

    settings = Settings(
        index_bucket="bucket",
        index_version="v3-abc1234",
        embed_model_id="amazon.titan-embed-text-v2:0",
    )

    with pytest.raises(EmbeddingModelMismatchError, match="titan-embed-text-v1"):
        retrieval.build_retriever(settings)


def test_build_retriever_fails_on_unreadable_manifest(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(retrieval.boto3, "client", lambda *a, **k: object())
    monkeypatch.setattr(retrieval, "download_index", lambda *a, **k: tmp_path)

    settings = Settings(index_bucket="bucket", index_version="v3-abc1234")

    with pytest.raises(IndexUnavailableError, match="unreadable manifest"):
        retrieval.build_retriever(settings)


def test_build_retriever_loads_a_matching_index(tmp_path: Path, monkeypatch) -> None:
    make_table(tmp_path)
    make_manifest().write(tmp_path / MANIFEST_FILENAME)
    monkeypatch.setattr(retrieval.boto3, "client", lambda *a, **k: object())
    monkeypatch.setattr(retrieval, "download_index", lambda *a, **k: tmp_path)
    monkeypatch.setattr(retrieval, "build_bedrock_client", lambda *a, **k: object())

    settings = Settings(index_bucket="bucket", index_version="v3-abc1234")
    retriever = retrieval.build_retriever(settings)

    assert retriever is not None
    assert retriever.index_version == "v3-abc1234"
