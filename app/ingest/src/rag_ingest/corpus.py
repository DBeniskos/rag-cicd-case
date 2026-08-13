"""Loading the source corpus.

CSV is read with the standard library rather than pandas: the job reads a few hundred rows once,
and pandas would add roughly 50 MB to an image whose whole point is to start quickly and exit.
"""

from __future__ import annotations

import csv
import hashlib
import sys
from dataclasses import dataclass
from pathlib import Path

import structlog

log = structlog.get_logger()

# Plot fields can exceed the default CSV field limit, which raises rather than truncating.
csv.field_size_limit(min(sys.maxsize, 2**31 - 1))


class CorpusError(RuntimeError):
    """The corpus could not be read, or contained nothing usable."""


@dataclass(frozen=True)
class Document:
    doc_id: str
    title: str
    text: str


def corpus_hash(path: Path) -> str:
    """Content hash of the source file.

    Recorded in the manifest so "is this index stale?" is answered by comparison rather than by
    guessing from timestamps.
    """
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return f"sha256:{digest.hexdigest()}"


def load_documents(
    path: Path,
    title_column: str,
    text_column: str,
    limit: int,
    min_chars: int = 200,
) -> list[Document]:
    """Read up to ``limit`` usable rows.

    Rows missing the expected columns are skipped rather than fatal — one malformed row in a
    public dataset should not fail a build — but a corpus that yields nothing is an error, because
    that means the column names are wrong and every later step would silently produce an empty
    index.
    """
    documents: list[Document] = []
    skipped = 0

    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise CorpusError(f"{path} has no header row")
        missing = {title_column, text_column} - set(reader.fieldnames)
        if missing:
            raise CorpusError(f"{path} is missing column(s): {', '.join(sorted(missing))}")

        for index, row in enumerate(reader):
            title = (row.get(title_column) or "").strip()
            text = (row.get(text_column) or "").strip()
            # Very short plots carry no retrievable content and only add noise to the index.
            if not title or len(text) < min_chars:
                skipped += 1
                continue
            documents.append(Document(doc_id=f"doc-{index:05d}", title=title, text=text))
            if len(documents) >= limit:
                break

    if not documents:
        raise CorpusError(f"{path} yielded no usable documents (skipped {skipped} rows)")

    log.info("corpus.loaded", documents=len(documents), skipped=skipped, source=str(path))
    return documents
