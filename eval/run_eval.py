"""Retrieval and answer quality gate for the RAG service.

    python eval/run_eval.py --base-url http://... --env nonprod/dev

Runs against a deployed environment, not an in-process app: a harness that imports the app cannot
see a stale index pointer, a missing IAM permission or a Bedrock quota. Gates both deploy.yml and
index.yml, since either can regress answer quality.

Stdlib only — it runs in the release path, so it must not depend on a package install.

Exit codes: 0 pass, 1 gate failed, 2 harness could not run.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import tomllib
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

REFUSAL_MARKERS = (
    "i don't know based on the indexed documents",
    "i dont know based on the indexed documents",
)

EXIT_PASS = 0
EXIT_GATE_FAILED = 1
EXIT_HARNESS_ERROR = 2


class HarnessError(RuntimeError):
    """The harness could not run. Distinct from the gate failing, and must not be conflated."""


@dataclass(frozen=True)
class Case:
    id: str
    question: str
    kind: str
    expect_doc: str | None = None
    expect_any: tuple[str, ...] = ()


@dataclass
class CaseResult:
    case: Case
    latency_ms: int = 0
    error: str | None = None
    answer: str = ""
    titles: tuple[str, ...] = ()
    recalled: bool = False
    answer_matched: bool = False
    refused: bool = False
    input_tokens: int = 0
    output_tokens: int = 0

    @property
    def ok(self) -> bool:
        return self.error is None

    @property
    def passed(self) -> bool:
        if not self.ok:
            return False
        if self.case.kind == "refusal":
            return self.refused
        return self.recalled and self.answer_matched

    def why_failed(self) -> str:
        if self.error:
            return self.error
        if self.case.kind == "refusal":
            return f"did not refuse: {self.answer[:80]}"
        if not self.recalled:
            return f"expected `{self.case.expect_doc}`, retrieved {list(self.titles[:3])}"
        return f"no expected term in: {self.answer[:80]}"


@dataclass
class Report:
    env: str
    base_url: str
    release: str = "unknown"
    index_version: str = "unknown"
    results: list[CaseResult] = field(default_factory=list)

    def metrics(self) -> dict[str, float]:
        grounded = [r for r in self.results if r.case.kind == "grounded" and r.ok]
        refusals = [r for r in self.results if r.case.kind == "refusal" and r.ok]
        latencies = [r.latency_ms for r in self.results if r.ok]

        return {
            "recall_at_k": _rate([r.recalled for r in grounded]),
            "answer_match_rate": _rate([r.answer_matched for r in grounded]),
            "refusal_rate": _rate([r.refused for r in refusals]),
            "error_rate": _rate([not r.ok for r in self.results]),
            "p95_latency_ms": _percentile(latencies, 0.95),
            "p50_latency_ms": _percentile(latencies, 0.50),
            "total_input_tokens": float(sum(r.input_tokens for r in self.results)),
            "total_output_tokens": float(sum(r.output_tokens for r in self.results)),
        }

    def as_dict(self, passed: bool, thresholds: dict[str, float]) -> dict[str, Any]:
        return {
            "env": self.env,
            "release": self.release,
            "index_version": self.index_version,
            "passed": passed,
            "metrics": self.metrics(),
            "thresholds": thresholds,
            "cases": [
                {
                    "id": r.case.id,
                    "kind": r.case.kind,
                    "passed": r.passed,
                    "latency_ms": r.latency_ms,
                    "recalled": r.recalled,
                    "answer_matched": r.answer_matched,
                    "refused": r.refused,
                    "error": r.error,
                    "answer": r.answer,
                    "titles": list(r.titles),
                }
                for r in self.results
            ],
        }


def _rate(flags: list[bool]) -> float:
    """An empty denominator scores 0, never 1 — a gate that measured nothing must not pass."""
    return sum(1 for f in flags if f) / len(flags) if flags else 0.0


def _percentile(values: list[int], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    # Nearest-rank: with ~18 samples, interpolation invents precision the sample size lacks.
    rank = max(0, min(len(ordered) - 1, round(q * len(ordered)) - 1))
    return float(ordered[rank])


def load_cases(path: Path) -> list[Case]:
    cases: list[Case] = []
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError as exc:
            raise HarnessError(f"{path}:{line_no} is not valid JSON: {exc}") from exc
        cases.append(
            Case(
                id=payload["id"],
                question=payload["question"],
                kind=payload.get("kind", "grounded"),
                expect_doc=payload.get("expect_doc"),
                expect_any=tuple(payload.get("expect_any", ())),
            )
        )
    if not cases:
        raise HarnessError(f"{path} contains no cases")
    return cases


def load_thresholds(path: Path, env: str) -> dict[str, float]:
    """Environment overrides win over defaults; an unknown environment gets the defaults."""
    try:
        config = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise HarnessError(f"cannot read {path}: {exc}") from exc

    merged = {**config.get("defaults", {}), **config.get("environments", {}).get(env, {})}
    if not merged:
        raise HarnessError(f"{path} defined no thresholds")
    return {key: float(value) for key, value in merged.items()}


def _headers() -> dict[str, str]:
    """/ask is authenticated in deployed environments; /version is not."""
    headers = {"Accept": "application/json"}
    api_key = os.environ.get("RAG_API_KEY", "")
    if api_key:
        headers["x-api-key"] = api_key
    return headers


def _get_json(url: str, timeout: int) -> dict[str, Any]:
    request = urllib.request.Request(url, headers=_headers())  # noqa: S310
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
        return json.loads(response.read().decode("utf-8"))


def _post_ask(base_url: str, question: str, timeout: int) -> dict[str, Any]:
    request = urllib.request.Request(  # noqa: S310
        f"{base_url}/ask",
        data=json.dumps({"question": question}).encode("utf-8"),
        headers={**_headers(), "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
        return json.loads(response.read().decode("utf-8"))


def is_refusal(answer: str) -> bool:
    return any(marker in answer.lower() for marker in REFUSAL_MARKERS)


def evaluate_case(base_url: str, case: Case, timeout: int) -> CaseResult:
    result = CaseResult(case=case)
    started = time.monotonic()
    try:
        payload = _post_ask(base_url, case.question, timeout)
    except urllib.error.HTTPError as exc:
        result.error = f"HTTP {exc.code}: {exc.read().decode('utf-8', errors='replace')[:200]}"
        return result
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        result.error = f"{type(exc).__name__}: {exc}"
        return result
    finally:
        result.latency_ms = int((time.monotonic() - started) * 1000)

    # Prefer the server's own timing: it excludes network jitter from the runner.
    result.latency_ms = int(payload.get("latency_ms") or result.latency_ms)
    result.answer = payload.get("answer", "")
    result.titles = tuple(p.get("title", "") for p in payload.get("passages", []))
    usage = payload.get("usage", {})
    result.input_tokens = int(usage.get("input_tokens", 0))
    result.output_tokens = int(usage.get("output_tokens", 0))
    result.refused = is_refusal(result.answer)

    if case.kind == "refusal":
        return result

    result.recalled = case.expect_doc is not None and case.expect_doc in result.titles
    lowered = result.answer.lower()
    # A refusal containing an expected term would otherwise score as a correct answer.
    result.answer_matched = not result.refused and any(
        term.lower() in lowered for term in case.expect_any
    )
    return result


def run(base_url: str, cases: list[Case], timeout: int, env: str) -> Report:
    report = Report(env=env, base_url=base_url)
    try:
        version = _get_json(f"{base_url}/version", timeout)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise HarnessError(f"/version unreachable at {base_url}: {exc}") from exc

    report.release = version.get("release", "unknown")
    report.index_version = version.get("index_version", "unknown")
    if report.index_version in ("", "none", "unknown"):
        raise HarnessError(
            f"no index is promoted in {env} (index_version={report.index_version!r}); "
            "run the index pipeline before gating on answer quality"
        )

    print(f"eval: {base_url} release={report.release} index={report.index_version}")
    for case in cases:
        result = evaluate_case(base_url, case, timeout)
        report.results.append(result)
        print(f"  {'PASS' if result.passed else 'FAIL'}  {case.id:<24} {result.latency_ms:>6}ms")
        if result.error:
            print(f"        error: {result.error}")
    return report


def check(metrics: dict[str, float], thresholds: dict[str, float]) -> list[tuple[str, bool, str]]:
    """Compare measurements against the gate. Returns (name, passed, detail) per check."""
    checks: list[tuple[str, bool, str]] = []

    for key in ("recall_at_k", "answer_match_rate", "refusal_rate"):
        if key in thresholds:
            actual, floor = metrics[key], thresholds[key]
            checks.append((key, actual >= floor, f"{actual:.0%} (min {floor:.0%})"))

    for key, ceiling_key, fmt in (
        ("error_rate", "max_error_rate", "{:.0%}"),
        ("p95_latency_ms", "max_p95_latency_ms", "{:.0f}ms"),
    ):
        if ceiling_key in thresholds:
            actual, ceiling = metrics[key], thresholds[ceiling_key]
            detail = f"{fmt.format(actual)} (max {fmt.format(ceiling)})"
            checks.append((key, actual <= ceiling, detail))

    return checks


def render_markdown(
    report: Report, metrics: dict[str, float], checks: list[tuple[str, bool, str]]
) -> str:
    passed = all(ok for _, ok, _ in checks)
    lines = [
        f"### Eval gate · `{report.env}` · {'PASS' if passed else 'FAIL'}",
        "",
        f"release `{report.release}` · index `{report.index_version}` · "
        f"{len(report.results)} cases",
        "",
        "| check | result | value |",
        "| --- | --- | --- |",
        *(f"| {name} | {'pass' if ok else '**fail**'} | {detail} |" for name, ok, detail in checks),
        "",
        f"p50 {metrics['p50_latency_ms']:.0f}ms · "
        f"{metrics['total_input_tokens']:.0f} in / {metrics['total_output_tokens']:.0f} out tokens",
    ]

    failures = [r for r in report.results if not r.passed]
    if failures:
        lines += [
            "",
            "<details><summary>Failing cases</summary>",
            "",
            "| case | why |",
            "| --- | --- |",
            *(f"| {r.case.id} | {r.why_failed().replace('|', '/')} |" for r in failures),
            "",
            "</details>",
        ]

    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--env", default="nonprod/dev")
    parser.add_argument("--golden-set", type=Path, default=here / "golden_set.jsonl")
    parser.add_argument("--thresholds", type=Path, default=here / "thresholds.toml")
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--json-out", type=Path, help="write the full report for artefact upload")
    parser.add_argument("--summary-out", type=Path, help="markdown out, e.g. $GITHUB_STEP_SUMMARY")
    args = parser.parse_args(argv)

    try:
        cases = load_cases(args.golden_set)
        thresholds = load_thresholds(args.thresholds, args.env)
        report = run(args.base_url.rstrip("/"), cases, args.timeout, args.env)
    except HarnessError as exc:
        print(f"eval: harness error: {exc}", file=sys.stderr)
        return EXIT_HARNESS_ERROR

    metrics = report.metrics()
    checks = check(metrics, thresholds)
    passed = all(ok for _, ok, _ in checks)

    print("")
    for name, ok, detail in checks:
        print(f"  {'PASS' if ok else 'FAIL'}  {name:<20} {detail}")
    print(f"\neval: {'PASS' if passed else 'FAIL'}")

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(
            json.dumps(report.as_dict(passed, thresholds), indent=2), encoding="utf-8"
        )

    if args.summary_out:
        with args.summary_out.open("a", encoding="utf-8") as handle:
            handle.write(render_markdown(report, metrics, checks) + "\n")

    return EXIT_PASS if passed else EXIT_GATE_FAILED


if __name__ == "__main__":
    sys.exit(main())
