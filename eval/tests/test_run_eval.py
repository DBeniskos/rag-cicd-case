"""Tests for the eval harness.

The harness is release-gating infrastructure: if it scores wrong, it either blocks good releases
or waves through bad ones. The cases below are the ones that would do real damage — an empty
denominator scoring 100%, a refusal counting as a correct answer, or a harness failure being
reported as a gate failure.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from run_eval import (
    EXIT_HARNESS_ERROR,
    Case,
    CaseResult,
    HarnessError,
    Report,
    _percentile,
    _rate,
    check,
    is_refusal,
    load_cases,
    load_thresholds,
    main,
    render_markdown,
)

EVAL_DIR = Path(__file__).resolve().parents[1]


def _case(kind: str = "grounded", **kwargs) -> Case:
    defaults = {
        "id": "c1",
        "question": "q",
        "kind": kind,
        "expect_doc": "Doc" if kind == "grounded" else None,
        "expect_any": ("term",) if kind == "grounded" else (),
    }
    return Case(**{**defaults, **kwargs})


class TestRate:
    def test_empty_scores_zero_not_one(self):
        # A harness that measured nothing must never report a perfect score.
        assert _rate([]) == 0.0

    def test_partial(self):
        assert _rate([True, True, False, False]) == 0.5


class TestPercentile:
    def test_empty(self):
        assert _percentile([], 0.95) == 0.0

    def test_single_value(self):
        assert _percentile([120], 0.95) == 120.0

    def test_nearest_rank_picks_a_real_sample(self):
        values = list(range(1, 21))
        assert _percentile(values, 0.95) == 19.0
        assert _percentile(values, 0.50) == 10.0


class TestRefusalDetection:
    def test_exact_refusal(self):
        assert is_refusal("I don't know based on the indexed documents.")

    def test_case_and_apostrophe_insensitive(self):
        assert is_refusal("i dont know based on the indexed documents")

    def test_real_answer_is_not_a_refusal(self):
        assert not is_refusal("The keeper recorded a second set of footprints in the snow.")


class TestCaseResult:
    def test_grounded_needs_both_recall_and_match(self):
        result = CaseResult(case=_case(), recalled=True, answer_matched=False)
        assert not result.passed

    def test_refusal_case_passes_only_when_refused(self):
        assert CaseResult(case=_case("refusal"), refused=True).passed
        assert not CaseResult(case=_case("refusal"), refused=False).passed

    def test_transport_error_fails_regardless(self):
        result = CaseResult(case=_case(), error="HTTP 503", recalled=True, answer_matched=True)
        assert not result.passed


class TestMetrics:
    def test_errored_cases_are_excluded_from_quality_but_counted_as_errors(self):
        report = Report(env="dev", base_url="http://x")
        report.results = [
            CaseResult(case=_case(), recalled=True, answer_matched=True, latency_ms=100),
            CaseResult(case=_case(), error="HTTP 500", latency_ms=50),
        ]
        metrics = report.metrics()
        # One of one *answered* grounded case was correct...
        assert metrics["recall_at_k"] == 1.0
        # ...but the failure is still visible, so a service that errors on half the set
        # cannot pass by scoring only what worked.
        assert metrics["error_rate"] == 0.5


class TestThresholds:
    def test_environment_overrides_default(self):
        thresholds = load_thresholds(EVAL_DIR / "thresholds.toml", "dev")
        assert thresholds["recall_at_k"] == 0.90
        assert thresholds["max_p95_latency_ms"] == 20000
        assert thresholds["answer_match_rate"] == 0.70

    def test_prod_is_stricter_than_dev(self):
        dev = load_thresholds(EVAL_DIR / "thresholds.toml", "dev")
        prod = load_thresholds(EVAL_DIR / "thresholds.toml", "prod")
        assert prod["max_p95_latency_ms"] < dev["max_p95_latency_ms"]
        assert prod["answer_match_rate"] > dev["answer_match_rate"]

    def test_unknown_environment_falls_back_to_defaults(self):
        thresholds = load_thresholds(EVAL_DIR / "thresholds.toml", "nope")
        assert thresholds["max_p95_latency_ms"] == 12000

    def test_empty_file_is_a_harness_error(self, tmp_path):
        (tmp_path / "empty.toml").write_text("# nothing\n", encoding="utf-8")
        with pytest.raises(HarnessError):
            load_thresholds(tmp_path / "empty.toml", "dev")

    def test_malformed_file_is_a_harness_error(self, tmp_path):
        (tmp_path / "bad.toml").write_text("[defaults\n", encoding="utf-8")
        with pytest.raises(HarnessError):
            load_thresholds(tmp_path / "bad.toml", "dev")


class TestCheck:
    def test_floors_and_ceilings_are_applied_in_the_right_direction(self):
        metrics = {
            "recall_at_k": 0.9,
            "answer_match_rate": 0.5,
            "refusal_rate": 1.0,
            "error_rate": 0.0,
            "p95_latency_ms": 9000.0,
        }
        thresholds = {
            "recall_at_k": 0.9,
            "answer_match_rate": 0.8,
            "refusal_rate": 1.0,
            "max_error_rate": 0.0,
            "max_p95_latency_ms": 12000.0,
        }
        results = {name: ok for name, ok, _ in check(metrics, thresholds)}
        assert results["recall_at_k"] is True  # exactly at the floor passes
        assert results["answer_match_rate"] is False
        assert results["p95_latency_ms"] is True


class TestGoldenSet:
    def test_parses_and_has_both_kinds(self):
        cases = load_cases(EVAL_DIR / "golden_set.jsonl")
        kinds = {c.kind for c in cases}
        assert kinds == {"grounded", "refusal"}
        assert len(cases) >= 15

    def test_ids_are_unique(self):
        cases = load_cases(EVAL_DIR / "golden_set.jsonl")
        assert len({c.id for c in cases}) == len(cases)

    def test_grounded_cases_reference_a_document_in_the_corpus(self):
        corpus_path = EVAL_DIR.parent / "data" / "raw" / "sample_movie_plots.csv"
        corpus = corpus_path.read_text(encoding="utf-8")
        for case in load_cases(EVAL_DIR / "golden_set.jsonl"):
            if case.kind == "grounded":
                assert case.expect_doc and case.expect_doc in corpus, case.id

    def test_malformed_line_is_a_harness_error(self, tmp_path):
        path = tmp_path / "bad.jsonl"
        path.write_text('{"id": "a"\n', encoding="utf-8")
        with pytest.raises(HarnessError):
            load_cases(path)


class TestRender:
    def test_failing_report_names_the_failing_case(self):
        report = Report(env="prod", base_url="http://x", release="v1.0.0", index_version="v2-abc")
        report.results = [CaseResult(case=_case(), recalled=False, titles=("Other",))]
        markdown = render_markdown(
            report, report.metrics(), [("recall_at_k", False, "0% (min 90%)")]
        )
        assert "FAIL" in markdown
        assert "c1" in markdown
        assert "Other" in markdown


class TestMain:
    def test_unreachable_url_exits_as_harness_error_not_gate_failure(self, tmp_path):
        # 2, not 1: "could not measure" and "measured and it is bad" are different incidents
        # and a pipeline should be able to tell them apart.
        code = main(
            [
                "--base-url",
                "http://127.0.0.1:9",  # discard port, refuses immediately
                "--env",
                "dev",
                "--timeout",
                "2",
                "--json-out",
                str(tmp_path / "out.json"),
            ]
        )
        assert code == EXIT_HARNESS_ERROR
        assert not (tmp_path / "out.json").exists()


class TestJsonReportShape:
    def test_report_is_serialisable(self):
        report = Report(env="dev", base_url="http://x")
        report.results = [CaseResult(case=_case(), recalled=True, answer_matched=True)]
        json.dumps(report.metrics())
