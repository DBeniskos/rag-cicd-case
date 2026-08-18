"""The /ask request path, including how AI-specific failure modes surface to callers."""

from __future__ import annotations

import pytest
from botocore.exceptions import ClientError
from conftest import FakeGenerator, FakeRetriever

from rag_api.generation import ModelThrottledError, ModelUnavailableError


def test_returns_503_with_a_machine_readable_code_when_no_index_is_promoted(make_client):
    with make_client() as client:
        response = client.post("/ask", json={"question": "Who hunts replicants?"})

    assert response.status_code == 503
    assert response.json()["code"] == "index_unavailable"


class TestApiKey:
    """Auth is enforced on /ask only, and only when a key is configured."""

    def test_rejects_a_missing_key(self, make_client):
        with make_client(
            retriever=FakeRetriever(), generator=FakeGenerator(), api_key="s3cret"
        ) as client:
            response = client.post("/ask", json={"question": "anything"})

        assert response.status_code == 401
        assert response.json()["code"] == "unauthorized"

    def test_rejects_a_wrong_key(self, make_client):
        with make_client(
            retriever=FakeRetriever(), generator=FakeGenerator(), api_key="s3cret"
        ) as client:
            response = client.post(
                "/ask", json={"question": "anything"}, headers={"x-api-key": "wrong"}
            )

        assert response.status_code == 401

    def test_accepts_the_right_key(self, make_client):
        with make_client(
            retriever=FakeRetriever(), generator=FakeGenerator(), api_key="s3cret"
        ) as client:
            response = client.post(
                "/ask", json={"question": "anything"}, headers={"x-api-key": "s3cret"}
            )

        assert response.status_code == 200

    def test_health_stays_open(self, make_client):
        # The ALB health check cannot present a key, and the smoke test has to identify the
        # running release before it holds credentials for anything.
        with make_client(api_key="s3cret") as client:
            assert client.get("/healthz").status_code == 200

    def test_no_key_configured_means_no_auth(self, make_client):
        with make_client(retriever=FakeRetriever(), generator=FakeGenerator()) as client:
            assert client.post("/ask", json={"question": "anything"}).status_code == 200


def test_returns_answer_passages_and_token_usage(make_client):
    with make_client(retriever=FakeRetriever(), generator=FakeGenerator()) as client:
        response = client.post("/ask", json={"question": "Who hunts replicants?"})

    body = response.json()
    assert response.status_code == 200
    assert body["answer"] == "A blade runner hunts replicants."
    assert body["index_version"] == "v7-deadbee"
    assert body["usage"] == {"input_tokens": 11, "output_tokens": 7}
    assert [p["doc_id"] for p in body["passages"]] == ["mp-001", "mp-002"]
    assert body["latency_ms"] >= 0


def test_falls_back_to_the_configured_top_k(make_client):
    retriever = FakeRetriever()
    with make_client(retriever=retriever, generator=FakeGenerator()) as client:
        client.post("/ask", json={"question": "Who hunts replicants?"})

    assert retriever.last_top_k == 2


def test_per_request_top_k_overrides_the_default(make_client):
    retriever = FakeRetriever()
    with make_client(retriever=retriever, generator=FakeGenerator()) as client:
        client.post("/ask", json={"question": "Who hunts replicants?", "top_k": 3})

    assert retriever.last_top_k == 3


def test_throttling_surfaces_as_429_with_retry_after(make_client):
    generator = FakeGenerator(error=ModelThrottledError("ThrottlingException"))
    with make_client(retriever=FakeRetriever(), generator=generator) as client:
        response = client.post("/ask", json={"question": "Who hunts replicants?"})

    assert response.status_code == 429
    assert response.json()["code"] == "model_throttled"
    assert response.headers["retry-after"] == "1"


def test_model_failure_surfaces_as_502_not_500(make_client):
    """A Bedrock outage is an upstream dependency failure, not a bug in this service."""
    generator = FakeGenerator(error=ModelUnavailableError("transport"))
    with make_client(retriever=FakeRetriever(), generator=generator) as client:
        response = client.post("/ask", json={"question": "Who hunts replicants?"})

    assert response.status_code == 502
    assert response.json()["code"] == "model_unavailable"


def test_rejects_an_empty_question(make_client):
    with make_client(retriever=FakeRetriever(), generator=FakeGenerator()) as client:
        assert client.post("/ask", json={"question": ""}).status_code == 422


def test_rejects_an_oversized_question(make_client):
    """An unbounded prompt is an unbounded bill; the cap is enforced before Bedrock is reached."""
    with make_client(retriever=FakeRetriever(), generator=FakeGenerator()) as client:
        response = client.post("/ask", json={"question": "x" * 1001})

    assert response.status_code == 422


def test_rejects_an_out_of_range_top_k(make_client):
    with make_client(retriever=FakeRetriever(), generator=FakeGenerator()) as client:
        assert client.post("/ask", json={"question": "hi", "top_k": 99}).status_code == 422


def test_an_unmapped_boto_error_is_not_swallowed(make_client):
    """Anything we have not classified must stay loud rather than degrade into a 200."""
    error = ClientError({"Error": {"Code": "AccessDeniedException"}}, "Converse")
    with (
        make_client(retriever=FakeRetriever(), generator=FakeGenerator(error=error)) as client,
        pytest.raises(ClientError),
    ):
        client.post("/ask", json={"question": "hi"})
