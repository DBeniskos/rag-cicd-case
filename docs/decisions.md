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

- **Version identity** — `v<n>-<git-sha>`. A counter so ordering is obvious to a human at 2am, and
  the SHA of the code that built it, so a bad index leads straight back to the chunking or
  embedding change responsible. Semver is deliberately not used here: an index is data, and
  "backward-incompatible" has no meaning for a rebuilt embedding set.
- **Immutability** — written once. `manifest.json` uploads **last**, so a partially uploaded index
  has no manifest and is never loadable. A multi-file upload behaves atomically for readers.
- **Compatibility** — the API refuses an index whose manifest declares a different embedding model
  or dimension count. A mismatch would otherwise produce confidently wrong retrieval instead of an
  error.

**What it costs.** Old versions accumulate in S3 (lifecycle-expired after 90 days). The ingestion
job needs its own IAM role, since it is the only principal permitted to write an index.

---

## 3. Rolling deploys in dev, gated blue/green in prod

| | dev | prod |
| --- | --- | --- |
| Strategy | `ROLLING` | `BLUE_GREEN` — both on the `ECS` controller |
| Traffic shift | in place | none until the gate passes, then 100%, then 5 min bake |
| Quality gate | after the deploy | **before any traffic moves** |
| Rollback trigger | pipeline redeploy; alarms and circuit breaker as backstops | gate verdict, then alarms |
| Approval | none | GitHub environment reviewer |

**Dev uses rolling updates.** Its purpose is fast feedback, and a second target group doubles ALB
rules and cost for an environment where a minute of degradation is free. What dev cannot do is gate
on answer quality *before* exposure — a rolling update replaces tasks in place, so there is no
second endpoint to judge first. Its eval therefore runs after the deploy, which is acceptable
precisely because dev is not where prod's safety comes from.

**Dev's rollback is the pipeline, not the circuit breaker, and that is a measured correction.** We
forced a deployment with an unpullable image and the circuit breaker did not reverse it in thirty
minutes, despite being enabled with `rollback = true`. The cause is visible in the service's own
configuration: `minimumHealthyPercent = 100` means the old healthy task is never stopped,
`resetOnHealthyTask` means the failure counter resets whenever a healthy task is observed, and the
threshold is 50% of a desired count of one. The counter kept resetting against a task that was
never going away. The service stayed up throughout — it fails safe — but it does not self-heal.
What restores dev is `deploy.yml`'s rollback step, which redeploys the previous digest and repairs
Terraform state. The circuit breaker and the alarms remain enabled as backstops; they are simply
not the mechanism to rely on at one task.

**Prod uses blue/green with a pre-shift quality gate.** ECS invokes a Lambda at
`POST_TEST_TRAFFIC_SHIFT`: the new task set is live on the test listener and carries no production
traffic, the Lambda runs `eval/run_eval.py` against it, and returns `SUCCEEDED` or `FAILED`. A
`FAILED` verdict makes ECS roll the deployment back instead of shifting traffic, so a release that
answers badly reaches nobody. The bundle vendors the same harness, golden set and thresholds the
pipeline uses, so the gate and CI can never disagree about what "good" means.

**Why not a canary.** A canary trades blast radius for observation time, and is the right answer
when correctness can *only* be judged from production traffic. That is not the case here, and the
earlier canary made the mismatch obvious. Its alarms watched `HTTPCode_Target_5XX_Count` and
`TargetResponseTime`, but the failure this service actually has is a confident, fluent, wrong
answer returned as HTTP 200 — invisible to both. Worse, the service has no organic traffic, so the
deployment had to generate the load its own alarms then measured: 10% of nothing produces no
datapoints, and with `treat_missing_data = notBreaching` the canary could not fail. It measured a
signal it manufactured, about a failure mode it could not see. A deterministic gate does not
depend on traffic volume at all.

**What we still accept.** Two environments means prod's release *mechanism* is never rehearsed
before it runs in prod: dev proves the application, not the shift. That is deliberate — a third
environment costs a permanently running ALB and two Fargate tasks. Second, the test listener must
be reachable from the internet, because the gate runs in Lambda and Lambda's egress address cannot
be allowlisted; what bounds the exposure is that `:8080` serves the same application as `:80` and
`/ask` rejects an unauthenticated caller on both, so only `/healthz` is readable and only while a
deployment is in flight. Moving the gate inside the VPC would need a NAT gateway or a second
internal load balancer, and neither is worth it here.

**At real scale this changes.** With meaningful traffic the gate stops being sufficient on its own,
because production reveals what no offline eval predicts — tail latency under concurrency, cache
behaviour, Bedrock throttling. The answer there is canary *after* the gate, scored against the old
task set as a control rather than against a fixed threshold, and on semantic metrics (abstention
rate, retrieval score distribution, grounding rate) rather than 5xx and latency. The gate never
becomes obsolete; it just stops being the whole story.


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

**Decision.** Dev and prod are fully separate Terraform stacks in one account, with the
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
