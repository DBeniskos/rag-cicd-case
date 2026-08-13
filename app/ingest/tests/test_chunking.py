from __future__ import annotations

import pytest

from rag_ingest.chunking import chunk_documents, chunk_text, split_sentences
from rag_ingest.corpus import Document


def test_split_sentences_drops_empty_fragments() -> None:
    assert split_sentences("One. Two!  Three?   ") == ["One.", "Two!", "Three?"]


def test_chunk_text_respects_the_size_limit() -> None:
    text = " ".join(f"Sentence number {i} here." for i in range(40))

    chunks = chunk_text(text, max_chars=120, overlap_chars=0)

    assert len(chunks) > 1
    assert all(len(chunk) <= 120 for chunk in chunks)


def test_chunk_text_overlaps_so_boundaries_stay_retrievable() -> None:
    """An answer spanning a boundary must survive in at least one chunk."""
    text = "Alpha sentence one. Bravo sentence two. Charlie sentence three. Delta sentence four."

    chunks = chunk_text(text, max_chars=45, overlap_chars=20)

    assert len(chunks) > 1
    # Consecutive chunks share a tail, so no wording falls between two chunks.
    assert any(chunks[0][-10:] in chunk for chunk in chunks[1:])


def test_chunk_text_keeps_an_oversized_sentence_whole() -> None:
    """Truncating mid-sentence can lose the answer; an oversized chunk merely retrieves fine."""
    long_sentence = "word " * 100

    chunks = chunk_text(long_sentence.strip() + ".", max_chars=50, overlap_chars=0)

    assert len(chunks) == 1
    assert chunks[0].startswith("word word")


@pytest.mark.parametrize("text", ["", "   ", "\n\n"])
def test_chunk_text_handles_empty_input(text: str) -> None:
    assert chunk_text(text, max_chars=100, overlap_chars=10) == []


def test_chunk_documents_prefixes_the_title() -> None:
    """A passage is retrieved alone, so it has to say what it is about."""
    documents = [Document(doc_id="d1", title="Blade Runner", text="A blade runner hunts.")]

    chunks = chunk_documents(documents, max_chars=500, overlap_chars=0)

    assert len(chunks) == 1
    assert chunks[0].text.startswith("Blade Runner. ")
    assert chunks[0].doc_id == "d1"
    assert chunks[0].ordinal == 0


def test_chunk_documents_numbers_chunks_within_a_document() -> None:
    text = " ".join(f"Sentence {i} of the plot." for i in range(30))
    documents = [Document(doc_id="d1", title="T", text=text)]

    ordinals = [chunk.ordinal for chunk in chunk_documents(documents, 100, 0)]

    assert ordinals == list(range(len(ordinals)))
