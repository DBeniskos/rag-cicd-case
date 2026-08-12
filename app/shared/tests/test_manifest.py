from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

import pytest
from pydantic import ValidationError

from rag_shared.manifest import MANIFEST_FILENAME, IndexManifest, index_prefix


def make_manifest() -> IndexManifest:
    return IndexManifest(
        index_version="v9-abc1234",
        embed_model_id="amazon.titan-embed-text-v2:0",
        embed_dimensions=1024,
        corpus_hash="sha256:deadbeef",
        doc_count=400,
        chunk_count=1183,
        git_sha="abc1234",
        built_at=datetime(2026, 8, 12, 9, 30, tzinfo=UTC),
    )


def test_manifest_round_trips_through_disk(tmp_path: Path) -> None:
    """Ingest writes it, the API reads it — the round trip is the contract."""
    original = make_manifest()
    path = tmp_path / MANIFEST_FILENAME

    original.write(path)

    assert IndexManifest.read(path) == original


def test_manifest_rejects_missing_fields(tmp_path: Path) -> None:
    path = tmp_path / MANIFEST_FILENAME
    path.write_text('{"index_version": "v1-abc"}', encoding="utf-8")

    with pytest.raises(ValidationError):
        IndexManifest.read(path)


def test_index_prefix_is_versioned_and_immutable() -> None:
    assert index_prefix("v9-abc1234") == "indexes/v9-abc1234/"
    assert index_prefix("v10-def5678") != index_prefix("v9-abc1234")
