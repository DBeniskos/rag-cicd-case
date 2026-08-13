"""Bedrock generation via the Converse API.

Converse rather than model-specific invoke_model payloads: changing model is one Terraform
variable and one IAM ARN. See docs/decisions.md.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

import boto3
import structlog
from botocore.config import Config as BotoConfig
from botocore.exceptions import BotoCoreError, ClientError

from rag_api.config import Settings
from rag_api.schemas import Passage, TokenUsage

log = structlog.get_logger()

SYSTEM_PROMPT = (
    "You answer questions strictly from the supplied context passages. "
    "If the passages do not contain the answer, reply exactly: "
    "I don't know based on the indexed documents. "
    "Never use outside knowledge. Keep answers under four sentences."
)

_THROTTLE_CODES = frozenset(
    {"ThrottlingException", "TooManyRequestsException", "ServiceQuotaExceededException"}
)


class ModelThrottledError(RuntimeError):
    """Rate or quota rejection — retryable, and a capacity signal."""


class ModelUnavailableError(RuntimeError):
    """Bedrock failed for a reason retrying will not fix within this request."""


@dataclass(frozen=True)
class Answer:
    text: str
    usage: TokenUsage


def build_prompt(question: str, passages: Sequence[Passage]) -> str:
    context = "\n\n".join(f"[{p.doc_id}] {p.title}\n{p.text}" for p in passages)
    return f"Context passages:\n\n{context}\n\nQuestion: {question}"


class BedrockGenerator:
    """Calls a Bedrock text model and translates its failure modes into ours."""

    def __init__(self, client: Any, model_id: str, max_output_tokens: int) -> None:
        self._client = client
        self.model_id = model_id
        self._max_output_tokens = max_output_tokens

    @classmethod
    def from_settings(cls, settings: Settings) -> BedrockGenerator:
        client = boto3.client(
            "bedrock-runtime",
            region_name=settings.aws_region,
            config=BotoConfig(
                connect_timeout=5,
                read_timeout=settings.bedrock_timeout_seconds,
                # Adaptive backs off on throttles instead of amplifying them.
                retries={"max_attempts": 3, "mode": "adaptive"},
            ),
        )
        return cls(client, settings.text_model_id, settings.max_output_tokens)

    def generate(self, question: str, passages: Sequence[Passage]) -> Answer:
        try:
            response = self._client.converse(
                modelId=self.model_id,
                system=[{"text": SYSTEM_PROMPT}],
                messages=[
                    {"role": "user", "content": [{"text": build_prompt(question, passages)}]}
                ],
                inferenceConfig={
                    "maxTokens": self._max_output_tokens,
                    # Zero temperature keeps the eval gate a measurement rather than a coin flip.
                    # topP is omitted: Anthropic rejects both sampling controls in one request.
                    "temperature": 0.0,
                },
            )
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            message = exc.response.get("Error", {}).get("Message", "")
            if code in _THROTTLE_CODES:
                log.warning("bedrock.throttled", model_id=self.model_id, error_code=code)
                raise ModelThrottledError(code) from exc
            # The provider's message is the only thing distinguishing a bad parameter from a
            # missing model, so it is logged even though it never reaches the caller.
            log.error(
                "bedrock.client_error",
                model_id=self.model_id,
                error_code=code,
                error_message=message,
            )
            raise ModelUnavailableError(code or "ClientError") from exc
        except BotoCoreError as exc:
            log.error("bedrock.transport_error", model_id=self.model_id, error=str(exc))
            raise ModelUnavailableError("transport") from exc

        usage = response.get("usage", {})
        return Answer(
            text=_extract_text(response),
            usage=TokenUsage(
                input_tokens=usage.get("inputTokens", 0),
                output_tokens=usage.get("outputTokens", 0),
            ),
        )


def _extract_text(response: dict[str, Any]) -> str:
    blocks = response.get("output", {}).get("message", {}).get("content", [])
    return "".join(block.get("text", "") for block in blocks).strip()
