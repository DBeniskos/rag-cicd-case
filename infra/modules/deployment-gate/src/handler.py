"""Deployment gate: ECS invokes this before production traffic moves.

At POST_TEST_TRAFFIC_SHIFT the new task set is reachable on the test listener and is carrying no
production traffic. The golden set runs against it there, so a release that answers badly is
rejected while its blast radius is still zero. Returning FAILED makes ECS roll the deployment back.

The eval harness is vendored into the bundle rather than reimplemented: the gate and the pipeline
must never disagree about what "good" means.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

import boto3

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))

import run_eval  # noqa: E402

_secrets = boto3.client("secretsmanager")
_elbv2 = boto3.client("elbv2")


def _api_key(secret_id: str) -> str:
    if not secret_id:
        return ""
    return _secrets.get_secret_value(SecretId=secret_id)["SecretString"]


def _test_url() -> str:
    """Resolved here rather than injected, so the service does not have to depend on this gate."""
    described = _elbv2.describe_load_balancers(Names=[os.environ["ALB_NAME"]])
    dns_name = described["LoadBalancers"][0]["DNSName"]
    return f"http://{dns_name}:{os.environ.get('TEST_PORT', '8080')}"


def _verdict(status: str, **detail: Any) -> dict[str, str]:
    print(json.dumps({"hookStatus": status, **detail}))
    return {"hookStatus": status}


def handler(event: dict[str, Any], _context: Any) -> dict[str, str]:
    stage = event.get("lifecycleStage", "UNKNOWN")
    execution_id = event.get("executionId", "")
    env = os.environ["RAG_ENV"]
    timeout = int(os.environ.get("CASE_TIMEOUT_SECONDS", "25"))

    try:
        base_url = _test_url()
        os.environ["RAG_API_KEY"] = _api_key(os.environ.get("API_KEY_SECRET_ID", ""))
        cases = run_eval.load_cases(HERE / "golden_set.jsonl")
        thresholds = run_eval.load_thresholds(HERE / "thresholds.toml", env)
        report = run_eval.run(base_url, cases, timeout, env)
    except run_eval.HarnessError as exc:
        # Being unable to measure the release is not permission to ship it.
        return _verdict("FAILED", stage=stage, executionId=execution_id, error=str(exc))
    except Exception as exc:  # noqa: BLE001 - an unhandled error here must not open the gate
        return _verdict(
            "FAILED", stage=stage, executionId=execution_id, error=f"{type(exc).__name__}: {exc}"
        )

    metrics = report.metrics()
    checks = run_eval.check(metrics, thresholds)
    passed = all(ok for _, ok, _ in checks)

    return _verdict(
        "SUCCEEDED" if passed else "FAILED",
        stage=stage,
        executionId=execution_id,
        release=report.release,
        indexVersion=report.index_version,
        checks=[{"name": n, "passed": ok, "detail": d} for n, ok, d in checks],
        failingCases=[r.case.id for r in report.results if not r.passed],
    )
