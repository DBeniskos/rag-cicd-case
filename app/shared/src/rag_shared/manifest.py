"""The index manifest — the contract between the ingestion job and the API.

Both sides import this module rather than declaring the schema twice. The manifest exists to make
an embedding-model mismatch impossible to miss, and two hand-maintained copies would be free to
drift, which is exactly the failure it guards against.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

from pydantic import BaseModel

MANIFEST_FILENAME = "manifest.json"
TABLE_NAME = "passages"


def index_prefix(index_version: str) -> str:
    """S3 key prefix for one index version.

    Versions are immutable: a rebuild writes a new prefix rather than mutating this one, which is
    what makes rollback a pointer flip instead of a restore.
    """
    return f"indexes/{index_version}/"


class IndexManifest(BaseModel):
    """How an index was built — enough to diagnose a bad one without rebuilding it.

    ``corpus_hash`` identifies the input documents, so "is the index stale?" is answerable by
    comparison rather than by guesswork.
    """

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
