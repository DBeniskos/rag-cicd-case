"""Bedrock boundary.

The happy path goes through ``botocore``'s stubber so the request is validated against the real
service model — that is what catches a misspelled ``inferenceConfig`` key or a cost cap that never
actually reaches the API. Failure mapping uses a raising fake instead, because botocore would
transparently retry a stubbed throttle and consume queued responses.
"""

from __future__ import annotations

import boto3
import pytest
from botocore.exceptions import ClientError, ConnectTimeoutError
from botocore.stub import ANY, Stubber

from rag_api.generation import (
    BedrockGenerator,
    ModelThrottledError,
    ModelUnavailableError,
    build_prompt,
)
from rag_api.schemas import Passage

MODEL_ID = "us.amazon.nova-lite-v1:0"

PASSAGES = [
    Passage(
        doc_id="mp-001", title="Blade Runner", text="A blade runner hunts replicants.", score=0.9
    ),
    Passage(doc_id="mp-002", title="Alien", text="A crew answers a distress signal.", score=0.6),
]


@pytest.fixture
def bedrock_client():
    return boto3.client(
        "bedrock-runtime",
        region_name="us-east-1",
        aws_access_key_id="testing",
        aws_secret_access_key="testing",
    )


def test_generate_returns_text_and_token_usage(bedrock_client):
    generator = BedrockGenerator(bedrock_client, MODEL_ID, max_output_tokens=256)
    service_response = {
        "output": {"message": {"role": "assistant", "content": [{"text": "A blade runner does."}]}},
        "stopReason": "end_turn",
        "usage": {"inputTokens": 120, "outputTokens": 18, "totalTokens": 138},
        "metrics": {"latencyMs": 412},
    }
    expected_request = {
        "modelId": MODEL_ID,
        "system": ANY,
        "messages": ANY,
        # The cost cap and the determinism setting must actually reach Bedrock.
        "inferenceConfig": {"maxTokens": 256, "temperature": 0.0},
    }

    with Stubber(bedrock_client) as stubber:
        stubber.add_response("converse", service_response, expected_request)
        answer = generator.generate("Who hunts replicants?", PASSAGES)

    assert answer.text == "A blade runner does."
    assert answer.usage.input_tokens == 120
    assert answer.usage.output_tokens == 18


def test_generate_concatenates_multiple_content_blocks(bedrock_client):
    generator = BedrockGenerator(bedrock_client, MODEL_ID, max_output_tokens=256)
    service_response = {
        "output": {
            "message": {
                "role": "assistant",
                "content": [{"text": "part one "}, {"text": "part two"}],
            }
        },
        "stopReason": "end_turn",
        "usage": {"inputTokens": 1, "outputTokens": 2, "totalTokens": 3},
        "metrics": {"latencyMs": 10},
    }

    with Stubber(bedrock_client) as stubber:
        stubber.add_response("converse", service_response)
        answer = generator.generate("q", PASSAGES)

    assert answer.text == "part one part two"


class _RaisingClient:
    def __init__(self, error: Exception) -> None:
        self._error = error

    def converse(self, **_kwargs: object) -> dict:
        raise self._error


@pytest.mark.parametrize(
    "code",
    ["ThrottlingException", "TooManyRequestsException", "ServiceQuotaExceededException"],
)
def test_capacity_errors_map_to_model_throttled(code):
    client = _RaisingClient(ClientError({"Error": {"Code": code}}, "Converse"))
    generator = BedrockGenerator(client, MODEL_ID, max_output_tokens=256)

    with pytest.raises(ModelThrottledError):
        generator.generate("q", PASSAGES)


def test_other_client_errors_map_to_model_unavailable():
    client = _RaisingClient(ClientError({"Error": {"Code": "AccessDeniedException"}}, "Converse"))
    generator = BedrockGenerator(client, MODEL_ID, max_output_tokens=256)

    with pytest.raises(ModelUnavailableError):
        generator.generate("q", PASSAGES)


def test_transport_failures_map_to_model_unavailable():
    client = _RaisingClient(
        ConnectTimeoutError(endpoint_url="https://bedrock-runtime.us-east-1.amazonaws.com")
    )
    generator = BedrockGenerator(client, MODEL_ID, max_output_tokens=256)

    with pytest.raises(ModelUnavailableError):
        generator.generate("q", PASSAGES)


def test_prompt_carries_every_retrieved_passage():
    prompt = build_prompt("Who hunts replicants?", PASSAGES)

    assert "Who hunts replicants?" in prompt
    for passage in PASSAGES:
        assert passage.doc_id in prompt
        assert passage.text in prompt
