# Design decisions

Six decisions that shaped this system, each with what it costs as well as what it buys. A decision
with no listed cost has not been thought about hard enough.

---

## 1. Vector store: LanceDB on S3, not OpenSearch or pgvector

**Context.** A corpus in the low thousands of chunks, a personal AWS account, and a hard
requirement that a bad index can be rolled back independently of the service.

| Option | Idle cost | Rollback | Operational surface |
| --- | --- | --- | --- |
| OpenSearch Serverless | ~$700/mo floor | reindex or snapshot restore | collection, policies, capacity |
| Aurora + pgvector | ~$50/mo minimum | migration or table swap | cluster, backups, pooling |
| **LanceDB on S3** | **~$0.02/mo** | **one SSM parameter write** | **a bucket** |

**Decision.** Each build is an immutable versioned prefix:

```
s3://rag-<env>-index/indexes/v3-a1b2c3d/
    manifest.json      embed model, dimensions, chunk count, corpus hash
    passages.lance/    the table
```

`/rag/<env>/active_index_version` in SSM names the live one. The API reads it at startup,
downloads the prefix to task-local disk, and serves from there.

**What it buys.** Rollback and promotion are the same operation with a different argument, bounded
by task restart time rather than a rebuild. Search is in-process — no network hop, no cluster to
size. Cost is rounding error.

**What it costs.** It does not scale past one node's disk and memory; the ceiling is roughly low
millions of vectors. Every task holds a full copy. Index freshness is bounded by task restart, so
promotion forces a rolling restart rather than being instant.

**Revisit when** the corpus exceeds ~1M chunks or sub-minute freshness is required. The migration
target is OpenSearch behind the same module boundary — `retrieval.py` is the seam.

---

## 2. The index is a release artifact with its own pipeline

**Context.** In RAG the deployable surface is larger than the container image. Answer quality
regresses with no code change at all — a re-chunked corpus, a new embedding model, a withdrawn
document.

Two anti-patterns rejected: **baking the index into the image** (every corpus change becomes a
full build and deploy, and rolling back a bad corpus drags the service back too), and **rebuilding
in place at deploy time** (destroys the previous index, so there is nothing to roll back to).

**Decision.** The index has its own version scheme, pipeline, and rollback path.

- **Version identity** — `v<n>-<corpus-hash>`. A counter so ordering is obvious to a human at 2am,
  a hash so an identical corpus is recognisable as such.
- **Immutability** — written once. `manifest.json` uploads **last**, so a partially uploaded index
  has no manifest and is never loadable. A multi-file upload behaves atomically for readers.
- **Compatibility** — the API refuses an index whose manifest declares a different embedding model
  or dimension count. A mismatch would otherwise produce confidently wrong retrieval instead of an
  error.

**What it costs.** Old versions accumulate in S3 (lifecycle-expired after 90 days). The ingestion
job needs its own IAM role, since it is the only principal permitted to write an index.

---

## 3. Rolling deploys in dev, blue/green in stage and prod

| | dev | stage | prod |
| --- | --- | --- | --- |
| Controller | `ECS` rolling | `CODE_DEPLOY` | `CODE_DEPLOY` |
| Traffic shift | in place | 10% canary → 5 min bake → 100% | same |
| Rollback trigger | circuit breaker | alarm on the *new* target group | same |
| Approval | none | none | GitHub environment reviewer |

**Dev uses rolling updates.** Its purpose is fast feedback, and a second target group doubles ALB
rules and cost for an environment where a minute of degradation is free. The circuit breaker
already covers the failure dev actually produces: a task that will not start.

**Stage and prod use blue/green** because the circuit breaker cannot catch a task that *starts
healthy and then serves badly* — the characteristic RAG failure, where the container is up,
`/healthz` is green, and every answer is wrong. Alarms on the replacement target group catch that
while only 10% of traffic is exposed.

**What it costs.** Two extra target groups and a CodeDeploy application per blue/green
environment. Rolling and blue/green fail differently, so the runbook documents them separately.

---

## 4. Bedrock through the Converse API, with the model id as a variable

**Context.** `invoke_model` takes provider-specific JSON and exposes every provider parameter.
`converse` normalises messages, system prompts, inference config and token usage across providers.

**Decision.** Use `converse`. The model id is a Terraform variable propagated as
`RAG_TEXT_MODEL_ID`, and the IAM policy derives its permitted ARNs from that same variable rather
than granting `bedrock:InvokeModel` on `*`.

**This paid for itself during the build.** The intended model was Claude Haiku. Every call failed
with `ResourceNotFoundException` — *"Model use case details have not been submitted for this
account"* — an out-of-band console approval that cannot be expressed in Terraform. Switching to
`us.amazon.nova-lite-v1:0` was one variable default. No application code changed. Under
`invoke_model` it would have been a rewrite of the request body, response parser and usage
extraction.

**What it costs.**

- Model ids must be **inference profile** ids, not bare foundation-model ids. Invoking one needs
  IAM permission on the profile *and* the underlying model in every region it may route to, so the
  policy strips the `us.`/`eu.`/`global.` prefix and grants three US regions.
- Provider-specific parameters are unavailable. Acceptable: this service uses `temperature` and
  `maxTokens`.
- Sampling parameters are not uniformly accepted — Anthropic rejects `temperature` and `topP`
  together with a `ValidationException`. The service sends `temperature: 0.0` alone, which also
  keeps the eval gate a measurement rather than a coin flip.

Switching back to Claude needs only the account's Anthropic form approved, then one variable.

---

## 5. One AWS account, two isolated stacks

**Context.** Separate accounts are the strongest isolation and the correct target state. This case
study runs in a single personal account, and building an Organizations landing zone would add
scope to an exercise whose subject is the pipeline.

**Decision.** Nonprod and prod are fully separate Terraform stacks in one account, with the
account boundary confined to a few variables so splitting later is configuration, not a rewrite.

**Separate per environment:** VPC, ALB, ECS cluster and service, task and execution roles, index
bucket, SSM namespace, log groups, alarms, state key.

**Deliberately shared:** the ECR repositories — because promoting *the same digest* dev → prod is
the whole point, and copying images between accounts weakens that guarantee — and the OIDC
provider.

**Compensating controls.** Three pipeline roles with disjoint permissions (CI reads, release
pushes to ECR, only deployment touches environments). The deployment role's trust policy is scoped
to the GitHub *environment* claim, so the prod approval gate sits in front of the credentials
rather than merely in front of the apply. Resource-level IAM confines each task role to its own
bucket prefix and SSM namespace.

**What it costs.** A misconfigured IAM policy could in principle reach across environments; two
accounts make that structurally impossible. No per-environment quotas or billing separation.

**Revisit when** this runs anywhere real. It is a scope decision, not an architectural preference.

---

## 6. The eval gate is deterministic — no LLM judge in the release path

**Context.** A RAG service can pass every unit test, deploy cleanly, report healthy and answer
badly. Options were LLM-as-judge, embedding similarity, or deterministic checks.

**Decision.** Deterministic only, over an 18-case golden set:

| Metric | Catches |
| --- | --- |
| `recall_at_k` | the expected document is not retrieved — what a bad index actually produces |
| `answer_match_rate` | retrieval worked and the model answered from its own weights anyway |
| `refusal_rate` | out-of-corpus questions answered instead of refused |
| `error_rate` | any non-2xx from `/ask` |
| `p95_latency_ms` | end-to-end regression including Bedrock |

**Why not a judge.** A gate must be **reproducible** — a judge model lets the same artifact pass
then fail, and a flaky gate gets overridden, which is worse than no gate. It must not **add
availability risk**: a judge puts a second Bedrock model between a deployment and its verdict, and
it fails exactly when the service is already under stress. It must be **cheap enough to run every
time** — 18 deterministic cases cost fractions of a cent, so the gate runs on every deploy and
every index promotion rather than nightly.

The refusal check does most of the work: the system prompt specifies an exact refusal string, so
containment is an exact measurement of prompt adherence.

**What it costs.** The gate cannot detect a subtly wrong but plausibly worded answer containing an
expected term. Accepted, because it reliably detects the regressions this pipeline actually
produces. The golden set needs maintenance — a test asserts every `expect_doc` still exists in the
corpus, so staleness fails CI rather than passing silently.

**Semantic scoring is relocated, not abandoned.** LLM-judge and RAGAS-style metrics belong in an
offline nightly review producing a trend line for humans, not a block/allow decision.

Two implementation details that matter more than they look: an empty denominator scores **0, never
100%**, so a harness that measured nothing cannot pass; and exit code **2 means "could not
measure"** while **1 means "measured and it is bad"** — different incidents, and a pipeline should
tell them apart.
