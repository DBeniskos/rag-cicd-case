"""The index manifest — the contract between the ingestion job and the API.

Both sides import this rather than declaring the schema twice, since two copies would be free to
drift into exactly the mismatch the manifest exists to catch.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

from pydantic import BaseModel

MANIFEST_FILENAME = "manifest.json"
TABLE_NAME = "passages"


def index_prefix(index_version: str) -> str:
    """S3 prefix for one immutable index version. A rebuild writes a new one, never mutates this."""
    return f"indexes/{index_version}/"


class IndexManifest(BaseModel):
    """How an index was built. ``corpus_hash`` makes "is this stale?" answerable by comparison."""

    index_version: str
    embed_model_id: str
    embed_dimensions: int
    corpus_hash: str
    doc_count: int
    chunk_count: int
    git_sha: str
    built_at: datetime

    @classmethod
    def read(cls, path: Path) -> IndexManifest:
        return cls.model_validate_json(path.read_text(encoding="utf-8"))

    def write(self, path: Path) -> None:
        path.write_text(self.model_dump_json(indent=2), encoding="utf-8")
