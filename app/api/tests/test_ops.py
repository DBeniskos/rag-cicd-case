"""Operational endpoints: the contract the load balancer and the deploy pipeline rely on."""

from __future__ import annotations


def test_healthz_returns_ok(make_client):
    with make_client() as client:
        response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_healthz_is_green_even_with_no_index_promoted(make_client):
    """Liveness must not depend on the index, or a bad index would drain every target."""
    with make_client() as client:
        assert client.get("/healthz").status_code == 200
        assert client.post("/ask", json={"question": "anything"}).status_code == 503


def test_version_reports_what_is_running(make_client):
    with make_client() as client:
        body = client.get("/version").json()

    assert body["release"] == "v1.2.3"
    assert body["git_sha"] == "abc1234"
    assert body["index_version"] == "none"
    assert body["embed_model_id"] == "amazon.titan-embed-text-v2:0"
    assert body["text_model_id"] == "anthropic.claude-3-5-haiku-20241022-v1:0"


def test_request_id_is_echoed_back(make_client):
    with make_client() as client:
        response = client.get("/healthz", headers={"x-request-id": "trace-me"})

    assert response.headers["x-request-id"] == "trace-me"


def test_request_id_is_generated_when_absent(make_client):
    with make_client() as client:
        assert client.get("/healthz").headers["x-request-id"]


def test_openapi_is_exposed_outside_prod(make_client):
    with make_client() as client:
        assert client.get("/openapi.json").status_code == 200
