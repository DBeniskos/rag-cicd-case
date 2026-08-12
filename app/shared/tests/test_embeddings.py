from __future__ import annotations

import io
import json
from typing import Any

import pytest

from rag_shared.embeddings import BedrockEmbedder, EmbeddingError

DIMENSIONS = 4


class FakeBedrock:
    """Returns a deterministic vector per input so ordering can be asserted."""

    def __init__(self, dimensions: int = DIMENSIONS, payload: dict[str, Any] | None = None) -> None:
        self._dimensions = dimensions
        self._payload = payload
        self.calls: list[dict[str, Any]] = []

    def invoke_model(self, **kwargs: Any) -> dict[str, Any]:
        body = json.loads(kwargs["body"])
        self.calls.append(body)
        payload = self._payload
        if payload is None:
            seed = float(len(body["inputText"]))
            payload = {"embedding": [seed] + [0.0] * (self._dimensions - 1)}
        return {"body": io.BytesIO(json.dumps(payload).encode())}


def test_embed_one_requests_normalised_vectors() -> None:
    client = FakeBedrock()
    embedder = BedrockEmbedder(client, "titan", dimensions=DIMENSIONS)

    vector = embedder.embed_one("abc")

    assert len(vector) == DIMENSIONS
    # Normalisation is what makes cosine distance meaningful on the query side.
    assert client.calls[0] == {"inputText": "abc", "dimensions": DIMENSIONS, "normalize": True}


def test_embed_one_rejects_unexpected_dimensionality() -> None:
    """A dimensionality surprise would corrupt the index silently, so it fails at the source."""
    client = FakeBedrock(payload={"embedding": [1.0, 2.0]})
    embedder = BedrockEmbedder(client, "titan", dimensions=DIMENSIONS)

    with pytest.raises(EmbeddingError, match="expected 4 dimensions"):
        embedder.embed_one("abc")


def test_embed_one_rejects_empty_response() -> None:
    embedder = BedrockEmbedder(FakeBedrock(payload={}), "titan", dimensions=DIMENSIONS)

    with pytest.raises(EmbeddingError, match="no embedding"):
        embedder.embed_one("abc")


def test_embed_many_preserves_input_order() -> None:
    """Order matters: embeddings are zipped back onto their chunks by position."""
    embedder = BedrockEmbedder(FakeBedrock(), "titan", dimensions=DIMENSIONS, max_workers=4)

    vectors = embedder.embed_many(["a", "bb", "ccc", "dddd"])

    assert [v[0] for v in vectors] == [1.0, 2.0, 3.0, 4.0]


def test_embed_many_handles_empty_input() -> None:
    embedder = BedrockEmbedder(FakeBedrock(), "titan", dimensions=DIMENSIONS)

    assert embedder.embed_many([]) == []
