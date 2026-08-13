"""Retrieval and answer quality gate for the RAG service.

    python eval/run_eval.py --base-url http://... --env nonprod/dev

Run against a *deployed* environment rather than an in-process app: the thing being gated is
"this release, on this index, in this environment", and a harness that imports the app cannot
see a stale index pointer, a missing IAM permission or a Bedrock quota. The cost of that choice
is that the harness needs a live URL; the benefit is that a pass means something.

The same harness gates two independent pipelines. deploy.yml runs it after a new *service*
version is live, index.yml runs it after a new *index* version is promoted. Either can regress
answer quality, and neither can be trusted to stay good because the other one was tested.

Exit codes: 0 pass, 1 gate failed, 2 harness could not run.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
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
        """Per-case verdict, used for the report. The gate itself scores rates, not cases."""
        if not self.ok:
            return False
        if self.case.kind == "refusal":
            return self.refused
        return self.recalled and self.answer_matched


@dataclass
class Report:
    env: str
    base_url: str
    release: str = "unknown"
    index_version: str = "unknown"
    results: list[CaseResult] = field(default_factory=list)

    @property
    def grounded(self) -> list[CaseResult]:
        return [r for r in self.results if r.case.kind == "grounded"]

    @property
    def refusals(self) -> list[CaseResult]:
        return [r for r in self.results if r.case.kind == "refusal"]

    def metrics(self) -> dict[str, float]:
        grounded_ok = [r for r in self.grounded if r.ok]
        refusal_ok = [r for r in self.refusals if r.ok]
        latencies = [r.latency_ms for r in self.results if r.ok]

        return {
            "recall_at_k": _rate([r.recalled for r in grounded_ok]),
            "answer_match_rate": _rate([r.answer_matched for r in grounded_ok]),
            "refusal_rate": _rate([r.refused for r in refusal_ok]),
            "error_rate": _rate([not r.ok for r in self.results]),
            "p95_latency_ms": _percentile(latencies, 0.95),
            "p50_latency_ms": _percentile(latencies, 0.50),
            "total_input_tokens": float(sum(r.input_tokens for r in self.results)),
            "total_output_tokens": float(sum(r.output_tokens for r in self.results)),
        }


def _rate(flags: list[bool]) -> float:
    """An empty denominator scores 0, never 1.

    A harness that silently passes because it measured nothing is the failure mode that makes
    quality gates worthless.
    """
    if not flags:
        return 0.0
    return sum(1 for f in flags if f) / len(flags)


def _percentile(values: list[int], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    # Nearest-rank: with ~18 samples, interpolation invents precision the sample size
    # does not support.
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
    """Read thresholds.yml without a YAML dependency.

    The file is deliberately flat key/value, so a 40-line parser removes a runtime dependency
    from the release path. If the schema ever needs anchors or lists, take the dependency —
    do not grow this.
    """
    thresholds: dict[str, float] = {}
    section: str | None = None
    current_env: str | None = None

    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        stripped = raw.strip()

        if indent == 0:
            section = stripped.rstrip(":")
            current_env = None
            continue

        if section == "defaults" and ":" in stripped:
            key, _, value = stripped.partition(":")
            thresholds[key.strip()] = float(value.split("#")[0].strip())
            continue

        if section == "environments":
            if stripped.endswith(":"):
                current_env = stripped.rstrip(":")
            elif current_env == env and ":" in stripped:
                key, _, value = stripped.partition(":")
                thresholds[key.strip()] = float(value.split("#")[0].strip())

    if not thresholds:
        raise HarnessError(f"{path} defined no thresholds")
    return thresholds


def _get_json(url: str, timeout: int) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})  # noqa: S310
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
        return json.loads(response.read().decode("utf-8"))


def _post_ask(base_url: str, question: str, timeout: int) -> dict[str, Any]:
    body = json.dumps({"question": question}).encode("utf-8")
    request = urllib.request.Request(  # noqa: S310
        f"{base_url}/ask",
        data=body,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
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
        detail = exc.read().decode("utf-8", errors="replace")[:200]
        result.error = f"HTTP {exc.code}: {detail}"
        return result
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        result.error = f"{type(exc).__name__}: {exc}"
        return result
    finally:
        result.latency_ms = int((time.monotonic() - started) * 1000)

    # Prefer the server's own timing when present: it excludes network jitter from a
    # runner that may be on the other side of the internet.
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
    # An expected term appearing inside the refusal string would score a refusal as a
    # correct answer, so refusals never count as matches.
    result.answer_matched = not result.refused and any(
        term.lower() in lowered for term in case.expect_any
    )
    return result


def run(base_url: str, cases: list[Case], timeout: int, env: str) -> Report:
    report = Report(env=env, base_url=base_url)
    try:
        version = _get_json(f"{base_url}/version", timeout)
        report.release = version.get("release", "unknown")
        report.index_version = version.get("index_version", "unknown")
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise HarnessError(f"/version unreachable at {base_url}: {exc}") from exc

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
        if key not in thresholds:
            continue
        actual, floor = metrics[key], thresholds[key]
        checks.append((key, actual >= floor, f"{actual:.0%} (min {floor:.0%})"))

    if "max_error_rate" in thresholds:
        actual, ceiling = metrics["error_rate"], thresholds["max_error_rate"]
        checks.append(("error_rate", actual <= ceiling, f"{actual:.0%} (max {ceiling:.0%})"))

    if "max_p95_latency_ms" in thresholds:
        actual, ceiling = metrics["p95_latency_ms"], thresholds["max_p95_latency_ms"]
        checks.append(
            ("p95_latency_ms", actual <= ceiling, f"{actual:.0f}ms (max {ceiling:.0f}ms)")
        )

    return checks


def render_markdown(report: Report, metrics: dict[str, float], checks: list[Any]) -> str:
    passed = all(ok for _, ok, _ in checks)
    lines = [
        f"### Eval gate · `{report.env}` · {'PASS' if passed else 'FAIL'}",
        "",
        f"release `{report.release}` · index `{report.index_version}` · "
        f"{len(report.results)} cases",
        "",
        "| check | result | value |",
        "| --- | --- | --- |",
    ]
    lines.extend(
        f"| {name} | {'pass' if ok else '**fail**'} | {detail} |" for name, ok, detail in checks
    )
    lines += [
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
        ]
        for r in failures:
            if r.error:
                why = r.error
            elif r.case.kind == "refusal":
                why = f"did not refuse: {r.answer[:80]}"
            elif not r.recalled:
                why = f"expected `{r.case.expect_doc}`, retrieved {list(r.titles[:3])}"
            else:
                why = f"no expected term in: {r.answer[:80]}"
            lines.append(f"| {r.case.id} | {why.replace('|', '/')} |")
        lines += ["", "</details>"]

    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--env", default="nonprod/dev")
    parser.add_argument("--golden-set", type=Path, default=here / "golden_set.jsonl")
    parser.add_argument("--thresholds", type=Path, default=here / "thresholds.yml")
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--json-out", type=Path, help="write the full report for artefact upload")
    parser.add_argument(
        "--summary-out", type=Path, help="write markdown, e.g. $GITHUB_STEP_SUMMARY"
    )
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
            json.dumps(
                {
                    "env": report.env,
                    "release": report.release,
                    "index_version": report.index_version,
                    "passed": passed,
                    "metrics": metrics,
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
                        for r in report.results
                    ],
                },
                indent=2,
            ),
            encoding="utf-8",
        )

    if args.summary_out:
        with args.summary_out.open("a", encoding="utf-8") as handle:
            handle.write(render_markdown(report, metrics, checks) + "\n")

    return EXIT_PASS if passed else EXIT_GATE_FAILED


if __name__ == "__main__":
    sys.exit(main())
