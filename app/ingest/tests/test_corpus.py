from __future__ import annotations

import csv
from pathlib import Path

import pytest

from rag_ingest.corpus import CorpusError, corpus_hash, load_documents

PLOT = "A long enough plot to survive the minimum length filter. " * 5


def write_csv(path: Path, rows: list[dict[str, str]], columns: list[str] | None = None) -> Path:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns or ["Title", "Plot"])
        writer.writeheader()
        writer.writerows(rows)
    return path


def test_load_documents_reads_expected_columns(tmp_path: Path) -> None:
    path = write_csv(tmp_path / "c.csv", [{"Title": "Alien", "Plot": PLOT}])

    documents = load_documents(path, "Title", "Plot", limit=10)

    assert len(documents) == 1
    assert documents[0].title == "Alien"
    assert documents[0].doc_id == "doc-00000"


def test_load_documents_honours_the_limit(tmp_path: Path) -> None:
    rows = [{"Title": f"Film {i}", "Plot": PLOT} for i in range(10)]
    path = write_csv(tmp_path / "c.csv", rows)

    assert len(load_documents(path, "Title", "Plot", limit=3)) == 3


def test_load_documents_skips_unusable_rows_without_failing(tmp_path: Path) -> None:
    """One malformed row in a public dataset should not fail a build."""
    rows = [
        {"Title": "Good", "Plot": PLOT},
        {"Title": "", "Plot": PLOT},
        {"Title": "Too short", "Plot": "tiny"},
    ]
    path = write_csv(tmp_path / "c.csv", rows)

    documents = load_documents(path, "Title", "Plot", limit=10)

    assert [d.title for d in documents] == ["Good"]


def test_load_documents_rejects_wrong_column_names(tmp_path: Path) -> None:
    """Wrong columns would otherwise produce an empty index that looks successful."""
    path = write_csv(tmp_path / "c.csv", [{"name": "x", "body": PLOT}], columns=["name", "body"])

    with pytest.raises(CorpusError, match="missing column"):
        load_documents(path, "Title", "Plot", limit=10)


def test_load_documents_rejects_a_corpus_with_nothing_usable(tmp_path: Path) -> None:
    path = write_csv(tmp_path / "c.csv", [{"Title": "x", "Plot": "tiny"}])

    with pytest.raises(CorpusError, match="no usable documents"):
        load_documents(path, "Title", "Plot", limit=10)


def test_corpus_hash_is_stable_and_content_sensitive(tmp_path: Path) -> None:
    """The manifest uses this to answer 'is the index stale?' by comparison."""
    a = tmp_path / "a.csv"
    a.write_text("Title,Plot\nx,y\n", encoding="utf-8")
    b = tmp_path / "b.csv"
    b.write_text("Title,Plot\nx,y\n", encoding="utf-8")
    c = tmp_path / "c.csv"
    c.write_text("Title,Plot\nx,z\n", encoding="utf-8")

    assert corpus_hash(a) == corpus_hash(b)
    assert corpus_hash(a) != corpus_hash(c)
    assert corpus_hash(a).startswith("sha256:")
