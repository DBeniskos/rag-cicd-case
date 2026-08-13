"""Splitting documents into retrievable passages.

Pure functions, no IO. Bad chunks do not raise — they just retrieve worse — so this is the part
that most needs to be testable in isolation.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from rag_ingest.corpus import Document

# A full sentence tokeniser would add a model download and a language assumption for marginal gain.
_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


@dataclass(frozen=True)
class Chunk:
    doc_id: str
    title: str
    text: str
    ordinal: int


def split_sentences(text: str) -> list[str]:
    return [part.strip() for part in _SENTENCE_END.split(text.strip()) if part.strip()]


def chunk_text(text: str, max_chars: int, overlap_chars: int) -> list[str]:
    """Pack sentences into chunks of at most ``max_chars``, repeating a tail for context.

    A sentence longer than ``max_chars`` is emitted whole: an oversized chunk retrieves fine, a
    truncated one can lose the answer entirely.
    """
    sentences = split_sentences(text)
    if not sentences:
        return []

    chunks: list[str] = []
    current = ""

    for sentence in sentences:
        if current and len(current) + 1 + len(sentence) > max_chars:
            chunks.append(current)
            tail = current[-overlap_chars:] if overlap_chars else ""
            current = f"{tail} {sentence}".strip() if tail else sentence
        else:
            current = f"{current} {sentence}".strip() if current else sentence

    if current:
        chunks.append(current)
    return chunks


def chunk_documents(documents: list[Document], max_chars: int, overlap_chars: int) -> list[Chunk]:
    """Chunk documents in order.

    The title is repeated into every chunk's stored text so a passage retrieved on its own still
    says what it is about — the generator sees passages, not documents.
    """
    chunks: list[Chunk] = []
    for document in documents:
        for ordinal, body in enumerate(chunk_text(document.text, max_chars, overlap_chars)):
            chunks.append(
                Chunk(
                    doc_id=document.doc_id,
                    title=document.title,
                    text=f"{document.title}. {body}",
                    ordinal=ordinal,
                )
            )
    return chunks
