# ADR-0006 — The eval gate is deterministic; no LLM judge in the release path

**Status:** accepted · **Date:** 2026-08 · **Decides:** what blocks a release on quality

## Context

A RAG service can pass every unit test, deploy cleanly, report healthy, and still answer badly.
Something has to measure answer quality and block a release on it. The usual options:

1. **LLM-as-judge** — a second model scores each answer for relevance and groundedness.
2. **Embedding similarity** — cosine distance between the answer and a reference answer.
3. **Deterministic checks** — retrieval position, string containment, refusal behaviour, latency.

LLM-as-judge produces the most nuanced signal and is genuinely better at detecting subtle
hallucination. It is also what most reference RAG pipelines reach for first.

## Decision

Gate on deterministic checks only. Specifically, over an 18-case golden set:

| Metric | What it catches |
| --- | --- |
| `recall_at_k` | the expected source document is not retrieved at all — the failure a bad index actually produces |
| `answer_match_rate` | retrieval worked and the model answered from its own weights anyway |
| `refusal_rate` | out-of-corpus questions are answered instead of refused — the RAG risk that matters |
| `error_rate` | any non-2xx from `/ask` |
| `p95_latency_ms` | end-to-end regression including Bedrock |

Thresholds are per environment in `eval/thresholds.yml`; prod is stricter than dev.

## Rationale

**A gate must be reproducible.** An LLM judge makes the gate itself non-deterministic: the same
release can pass and then fail with no change to the artefact. A flaky gate gets overridden, and an
overridden gate is worse than no gate, because it teaches the team that red means "retry".

**A gate must not add availability risk to the release path.** A judge model puts a second Bedrock
model between a deployment and its verdict. When Bedrock throttles — which is exactly when the
service is under stress — the gate fails for reasons unrelated to the release.

**A gate must be cheap enough to run every time.** 18 deterministic cases cost fractions of a cent
and run in under a minute, so the gate runs on every deploy and every index promotion rather than
nightly.

**The refusal check is doing most of the work.** Three out-of-corpus questions with a required
100% refusal rate catch the specific behaviour that makes a RAG service dangerous: improvising.
That check needs no judge — the system prompt specifies an exact refusal string, so containment is
an exact measurement of prompt adherence.

## Consequences

- The gate cannot detect a subtly wrong but plausibly worded answer that happens to contain an
  expected term. Accepted: it reliably detects retrieval failure, prompt-adherence failure and
  refusal failure, which are the regressions this pipeline actually produces.
- The golden set requires maintenance as the corpus changes. A test asserts every `expect_doc`
  still exists in the corpus, so a stale golden set fails CI rather than silently passing.
- `answer_match_rate` is a floor, not a target, and the thresholds are set just under what the
  current corpus and model sustain. A number nothing can fail is decoration.
- **Semantic scoring is not abandoned, it is relocated.** LLM-judge and RAGAS-style metrics belong
  in an offline nightly quality review whose output is a trend line for humans, not a block/allow
  decision. That is the documented next step.
- The harness distinguishes "could not measure" (exit 2) from "measured and it is bad" (exit 1),
  and an empty denominator scores 0 rather than 100%. A harness that silently passes because it
  measured nothing is the failure mode that makes quality gates worthless.
