from __future__ import annotations

from collections.abc import Iterator, Sequence
from contextlib import contextmanager

import pytest
from fastapi.testclient import TestClient

from rag_api.config import Settings
from rag_api.generation import Answer
from rag_api.main import create_app
from rag_api.schemas import Passage, TokenUsage

PASSAGES = [
    Passage(
        doc_id="mp-001", title="Blade Runner", text="A blade runner hunts replicants.", score=0.92
    ),
    Passage(doc_id="mp-002", title="Alien", text="A crew answers a distress signal.", score=0.71),
    Passage(
        doc_id="mp-003", title="Arrival", text="A linguist decodes an alien language.", score=0.55
    ),
]


class FakeRetriever:
    """Stands in for the vector store so the request path is testable without S3 or Bedrock."""

    def __init__(self, passages: Sequence[Passage] = PASSAGES, index_version: str = "v7-deadbee"):
        self.index_version = index_version
        self._passages = list(passages)
        self.last_top_k: int | None = None

    def search(self, question: str, top_k: int) -> list[Passage]:
        self.last_top_k = top_k
        return self._passages[:top_k]


class FakeGenerator:
    def __init__(
        self, answer: str = "A blade runner hunts replicants.", error: Exception | None = None
    ):
        self.model_id = "fake-model"
        self._answer = answer
        self._error = error

    def generate(self, question: str, passages: Sequence[Passage]) -> Answer:
        if self._error is not None:
            raise self._error
        return Answer(text=self._answer, usage=TokenUsage(input_tokens=11, output_tokens=7))


@pytest.fixture
def settings() -> Settings:
    return Settings(
        env="local",
        release_version="v1.2.3",
        git_sha="abc1234",
        index_bucket="",
        index_version="none",
        top_k=2,
        max_output_tokens=256,
    )


@pytest.fixture
def make_client(settings: Settings):
    """Build a client, optionally swapping in fake collaborators after startup."""

    @contextmanager
    def _make(
        retriever: object | None = None, generator: object | None = None
    ) -> Iterator[TestClient]:
        app = create_app(settings)
        with TestClient(app) as client:
            if retriever is not None:
                app.state.retriever = retriever
            if generator is not None:
                app.state.generator = generator
            yield client

    return _make
