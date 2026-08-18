from __future__ import annotations

import pytest
from pydantic import ValidationError

from rag_api.config import NO_INDEX, Settings


def test_settings_come_from_prefixed_environment_variables(monkeypatch):
    monkeypatch.setenv("RAG_ENV", "prod")
    monkeypatch.setenv("RAG_INDEX_BUCKET", "rag-prod-index")
    monkeypatch.setenv("RAG_INDEX_VERSION", "v9-cafe123")
    monkeypatch.setenv("RAG_TOP_K", "6")

    settings = Settings()

    assert settings.env == "prod"
    assert settings.index_bucket == "rag-prod-index"
    assert settings.index_version == "v9-cafe123"
    assert settings.top_k == 6


def test_a_fresh_environment_reports_no_promoted_index():
    assert Settings().index_version == NO_INDEX


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("top_k", 0),
        ("top_k", 21),
        ("max_output_tokens", 0),
        ("max_output_tokens", 8192),
        ("bedrock_timeout_seconds", 0),
        ("bedrock_timeout_seconds", 61),
    ],
)
def test_cost_and_latency_caps_are_enforced_at_the_boundary(field, value):
    """A typo in a tfvars file should fail the task, not quietly uncap spend."""
    with pytest.raises(ValidationError):
        Settings(**{field: value})


def test_unknown_environment_variables_are_rejected():
    with pytest.raises(ValidationError):
        Settings(env="staging")


# Every environment under infra/envs must appear here, or its tasks crash on startup with a
# validation error rather than serving. Caught the hard way when a new environment was deployed.
@pytest.mark.parametrize("env", ["local", "dev", "prod"])
def test_every_deployed_environment_name_is_accepted(env):
    assert Settings(env=env).env == env
