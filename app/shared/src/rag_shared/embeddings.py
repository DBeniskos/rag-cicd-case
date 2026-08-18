"""Bedrock embeddings, shared by the ingestion job and the API.

A question must be embedded by exactly the same model, dimensionality and normalisation as the
corpus was, or retrieval degrades into confident nonsense instead of failing. Sharing one
implementation makes that structural rather than a code-review promise.
"""

from __future__ import annotations

import json
from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor
from typing import Any

import boto3
import structlog
from botocore.config import Config as BotoConfig
from botocore.exceptions import BotoCoreError, ClientError

log = structlog.get_logger()

TITAN_V2_DIMENSIONS = 1024


class EmbeddingError(RuntimeError):
    """Bedrock could not produce a usable embedding."""


def build_bedrock_client(region: str, timeout_seconds: float) -> Any:
    return boto3.client(
        "bedrock-runtime",
        region_name=region,
        config=BotoConfig(
            connect_timeout=5,
            read_timeout=timeout_seconds,
            # Adaptive retries back off on throttles rather than amplifying them, which matters
            # against a per-account Bedrock quota shared with the inference path.
            retries={"max_attempts": 4, "mode": "adaptive"},
        ),
    )


class BedrockEmbedder:
    """Titan Text Embeddings V2.

    Vectors are requested unit-normalised so cosine distance is the meaningful metric on both the
    ingest and query sides.
    """

    def __init__(
        self,
        client: Any,
        model_id: str,
        dimensions: int = TITAN_V2_DIMENSIONS,
        max_workers: int = 8,
    ) -> None:
        self._client = client
        self.model_id = model_id
        self.dimensions = dimensions
        self._max_workers = max_workers

    def embed_one(self, text: str) -> list[float]:
        body = json.dumps({"inputText": text, "dimensions": self.dimensions, "normalize": True})
        try:
            response = self._client.invoke_model(
                modelId=self.model_id,
                body=body,
                accept="application/json",
                contentType="application/json",
            )
            payload = json.loads(response["body"].read())
        except (BotoCoreError, ClientError) as exc:
            log.error("bedrock.embed_failed", model_id=self.model_id, error=str(exc))
            raise EmbeddingError(f"embedding call failed for {self.model_id}") from exc

        vector = payload.get("embedding")
        if not vector:
            raise EmbeddingError("Bedrock returned no embedding")
        # A dimensionality surprise would corrupt the index silently, so it is caught at the source.
        if len(vector) != self.dimensions:
            raise EmbeddingError(f"expected {self.dimensions} dimensions, got {len(vector)}")
        return [float(value) for value in vector]

    def embed_many(self, texts: Sequence[str]) -> list[list[float]]:
        """Embed in input order.

        Titan accepts one input per call, so a few thousand chunks is a few thousand calls. Bounded
        concurrency keeps an ingest to about a minute without amplifying throttling.
        """
        if not texts:
            return []
        with ThreadPoolExecutor(max_workers=self._max_workers) as pool:
            return list(pool.map(self.embed_one, texts))
