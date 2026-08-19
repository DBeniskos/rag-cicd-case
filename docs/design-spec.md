# Design specification

CI/CD pipeline for a GenAI RAG microservice on AWS.

This document explains *why* the system is shaped the way it is. What it does and how to run it are
in the [README](../README.md); how to operate it when it breaks is in the
[runbook](runbook.md); the individual decisions and their trade-offs are in
[decisions](decisions.md).

---

## 1. The problem, stated precisely

A retrieval-augmented generation service is not a normal microservice with a model bolted on. It
has **three independently versioned things that can each break production on their own**:

| Artefact | Changes when | Fails as |
| --- | --- | --- |
| **Container image** | code changes | crash, 5xx, latency |
| **Index** | corpus, chunking or embedding model changes | wrong answers, healthy service |
| **Model** | a provider deprecates, throttles, or gates a model | 429, 502, silent quality drift |

A pipeline that only versions the first of these is a pipeline that cannot roll back two of its
three failure modes. Almost everything below follows from taking that seriously.

The second consequence: **"the deployment succeeded" and "the service is answering correctly" are
different claims**, and only the first is normally measured. A RAG service can pass every unit
test, deploy cleanly, report `/healthz` green, and answer every question wrong — because the index
pointer moved, or a prompt changed, or the model was swapped. So the pipeline measures the second
claim explicitly, on every deploy and every index promotion.

---

## 2. Architecture

```
 GitHub ──OIDC──► 3 scoped roles ──► AWS
   │                                  │
   │  ci.yml       (read only)        │
   │  release.yml  (push to ECR)      │
   │  deploy.yml   (apply an env)     │
   │  index.yml    (build + promote)  │
   │                                  │
   ▼                                  ▼
 ┌──────────────────────────────────────────────────────────┐
 │  ALB ──► ECS Fargate: rag-<env>-api                      │
 │            │                                             │
 │            ├── retrieval: LanceDB, local disk            │
 │            │      ▲ downloaded at startup                │
 │            │      │                                      │
 │            └── generation: Bedrock Converse              │
 │                                                          │
 │  SSM /rag/<env>/active_index_version ──► which index     │
 │  S3  rag-<env>-index/indexes/v<n>-<hash>/ ─┘             │
 │                                    ▲                     │
 │  one-off ECS task: rag-<env>-ingest┘  (own IAM role)     │
 └──────────────────────────────────────────────────────────┘
              │
              └──► Bedrock: Titan Embeddings V2 · Nova Lite
                   IAM scoped to exactly those model ARNs
```

**Why ECS Fargate and not Lambda.** The index is hundreds of megabytes and is downloaded at
startup. Lambda would pay that cost on every cold start and cap the index at the ephemeral storage
limit. A long-lived task amortises the download across the task's lifetime, which is the right
shape for a workload whose state is large and read-mostly.

**Why ECS Fargate and not EKS.** One service and one batch job do not justify a control plane, a
node group and a Kubernetes upgrade cadence. If this platform grew to twenty services the
calculation reverses.

**Why the index lives on local disk rather than being queried over the network.** See
[decisions §1](decisions.md#1-vector-store-lancedb-on-s3-not-opensearch-or-pgvector). The short
version: at this corpus size the alternatives cost
between 50x and 30,000x more per month and make rollback a restore operation instead of a pointer
write.

---

## 3. The two release paths

This is the core of the design.

```
 SERVICE                              INDEX
 ───────                              ─────
 PR ──► ci.yml                        corpus change
   lint, test, coverage, image build      │
   terraform fmt/validate/plan            ▼
   CodeQL                              index.yml: build-and-promote
        │                                 runs rag-ingest as a one-off ECS task
        ▼                                 writes s3://.../indexes/v<n>-<hash>/  (immutable)
 merge ──► release.yml                    writes SSM active_index_version
   build once, tag, push to ECR           forces rolling restart
   Trivy scan, SBOM                       │
   reject a duplicate version             ▼
        │                              smoke + EVAL GATE
        ▼                                 │
 deploy.yml ──► resolve tag to DIGEST     ▼
   terraform apply                     rollback: one pointer write
   rolling (dev) | gated blue/green (prod)
        │
        ▼
 prod only: EVAL GATE before traffic moves
   ECS lifecycle hook @ POST_TEST_TRAFFIC_SHIFT
   FAILED ⇒ roll back, nobody served
        │
        ▼
 smoke + EVAL GATE
        │
        ▼
 rollback: redeploy previous digest
```

**Neither path can force the other to move.** A corpus fix does not require a service release; a
service fix does not require an index rebuild. Two failure domains, two rollbacks, two runbook
sections.

### Build once, promote by digest

`release.yml` builds each image exactly once and pushes it with two tags: the semantic version and
`sha-<commit>`. No `latest`, and no moving alias tags — the repository is `IMMUTABLE`, so a tag can
never be repointed. `deploy.yml` never builds. It resolves the requested version tag to an **image
digest** and deploys that.

This matters because a tag records what someone *intended* and a digest records which bytes *ran*.
Rebuilding from the same source in a later pipeline stage produces a different image — different
base-layer patches, different timestamps — so "dev and prod run the same code" would be a hope
rather than a fact. Deploying by digest makes it a fact.

`release.yml` also refuses to publish a version tag that already exists in ECR. Immutable releases
are only immutable if something enforces it. This guard fired for real during the build, twice.

AWS's own guidance on [semantic versioning for continuous deployment](https://aws.amazon.com/blogs/containers/enable-continuous-deployment-based-on-semantic-versioning-using-aws-app-runner/)
lands in the same place: tag each release with an exact semver plus a commit-derived tag, and do
not track `latest`. Where it differs is the trigger — it deploys automatically on an ECR push
event, whereas this pipeline requires an explicit dispatch and a reviewer on prod.

### Identity: three roles, not one

| Role | Trusted from | Can do |
| --- | --- | --- |
| `rag-role-cipipeline` | pull requests | read ECR, `terraform plan` (read-only AWS) |
| `rag-role-releasepipeline` | `main` | push to ECR — and nothing else |
| `rag-role-deploymentpipeline` | GitHub `environment` claim | `terraform apply`, ECS, ELB, SSM |

No long-lived AWS keys exist anywhere. The prod deployment role is trusted only from a job running
in the `prod` GitHub environment, which has a required reviewer — so **the approval gate sits in
front of the credentials, not merely in front of the apply**. A compromised workflow file on a
branch cannot mint prod credentials.

> **A finding worth recording.** GitHub's OIDC subject claim is not
> `repo:<owner>/<repo>:pull_request` when immutable actions are enabled — it is
> `repo:<owner>@<owner-id>/<repo>@<repo-id>:pull_request`. Every `AssumeRoleWithWebIdentity` call
> failed until this was diagnosed from the `principalId` in a CloudTrail `lookup-events` result.
> Pinning to numeric IDs turned out to be *stronger* than pinning to names, because names can be
> transferred and IDs cannot.

---

## 4. The eval gate

`eval/run_eval.py` runs an 18-case golden set against a **live deployed environment** and blocks
the pipeline on five measurements: retrieval recall, answer-term match rate, refusal rate on
out-of-corpus questions, error rate, and p95 latency. Thresholds are per environment; prod is
stricter than dev.

It runs against a deployed URL rather than an in-process app on purpose. The thing being gated is
"this release, on this index, in this environment" — a harness that imports the app cannot see a
stale index pointer, a missing IAM permission or a Bedrock quota. The cost is that it needs a live
URL. The benefit is that a pass means something.

**The gate is deliberately deterministic — no LLM judge.** A judge model makes the gate itself
irreproducible and adds a second model's availability to the release path, so the same artefact can
pass and then fail. A flaky gate gets overridden, and an overridden gate is worse than no gate.
Full reasoning and the rejected alternatives are in
[decisions §6](decisions.md#6-the-eval-gate-is-deterministic--no-llm-judge-in-the-release-path).

Two details that matter more than they look:

- **An empty denominator scores 0, never 100%.** A harness that silently passes because it measured
  nothing is the specific failure that makes quality gates worthless.
- **Exit 2 means "could not measure"; exit 1 means "measured and it is bad".** These are different
  incidents and a pipeline should be able to tell them apart.

---

## 5. Security

| Control | Implementation |
| --- | --- |
| No static credentials | GitHub OIDC → three scoped roles, pinned to numeric owner/repo IDs |
| Caller authentication | `/ask` requires `x-api-key`, compared in constant time; the key lives in Secrets Manager |
| Secret delivery | ECS agent resolves it via the **execution** role, so it never enters the task definition and the task role cannot read it |
| CI cannot read secrets | the CI role carries an explicit `Deny` on `secretsmanager:GetSecretValue` that outranks its managed read-only policy |
| Least privilege on the model | `bedrock:InvokeModel` on exactly the two model ARNs in use, plus the inference-profile ARN |
| Least privilege on the index | API role is read-only on the index prefix; only the ingest role can write |
| Container hardening | multi-stage build, non-root UID 10001, no shell in the final layer |
| Image scanning | Trivy on every release; ECR scan-on-push |
| Static analysis | CodeQL and Ruff's bandit rules in the PR gate |
| Encryption | S3 SSE, Secrets Manager, SSM SecureString, TLS in transit |
| Branch protection | linear history, no force-push, PR required, `enforce_admins: true` |

**The AI-specific control worth calling out** is scoping Bedrock permissions to named model ARNs.
`bedrock:InvokeModel` on `*` is the default reach-for and it means a compromised task can invoke a
frontier model at 50x the price, and a typo in a model id fails silently in the bill instead of
loudly in the logs. Deriving the ARNs from the same variable the application reads keeps the policy
and the configuration from drifting apart.

---

## 6. Observability

Structured JSON logs (structlog) to CloudWatch, correlated by request id. Every `/ask` logs
retrieval latency, generation latency, index version, model id, and **input and output token
counts** — cost is observable per request rather than only on the monthly bill.

Alarms: running task count at zero, ALB 5xx rate, p95 target response time, Bedrock throttle count,
and a token-spend threshold. The first four page; the last one is a budget signal.

One logging decision earned its place: **the provider's error message is logged on the Bedrock
failure path even though it never reaches the caller**. `ResourceNotFoundException` alone sent
three separate investigations in the wrong direction. The message — *"Model use case details have
not been submitted for this account"* — resolved it in seconds. Error codes are for machines;
messages are for humans, and the human is the one on the incident call.

---

## 7. What is deliberately not here

Being explicit about scope is part of the design.

| Not built | Why | What it would take |
| --- | --- | --- |
| Separate AWS accounts | scope: this is a pipeline exercise, not a landing zone. Compensated with scoped roles and environment-gated credentials — [decisions §5](decisions.md) | Organizations, cross-account roles, a second state bucket |
| Per-caller identity on `/ask` | a single shared key authenticates *that a caller is allowed*, not *which* caller | Cognito or an API Gateway authorizer, plus per-client keys and rate limits |
| LLM-as-judge scoring | would make the release gate irreproducible — [decisions §6](decisions.md) | a nightly offline job producing a trend line, not a gate |
| Autoscaling | the load profile is a demo | target-tracking on ALB request count per target |
| WAF, Shield, private subnets with NAT | cost, in a personal account, for no demonstrative value | a NAT gateway is ~$32/month by itself |
| Multi-region | the failure domain is one region by choice | cross-region index replication and a Route 53 health check |

---

## 8. Cost

| Component | Monthly (dev, continuous) |
| --- | --- |
| Fargate, 1 × 0.5 vCPU / 1 GB | ~$15 |
| Application Load Balancer | ~$18 |
| S3, index and corpus | < $0.10 |
| Bedrock, demo traffic | < $1 |
| CloudWatch logs and alarms | ~$2 |

Roughly $0.85/day for dev. A $20 monthly budget with alerts at 80% actual and 100% forecast is
created by `bootstrap.sh` — the alarm exists because an unbounded prompt is the only component here
with an unbounded cost curve, which is also why `max_output_tokens` is capped in configuration
rather than left to the model.

Scaling dev to zero between demos costs one command and is in the runbook.
