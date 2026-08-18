# rag-cicd-case — CI/CD for a GenAI RAG microservice on AWS

A production-shaped delivery pipeline for a retrieval-augmented generation (RAG) service on AWS.
The AI logic is deliberately small. **The pipeline, the release engineering and the operability are
the deliverable.**

> Case study for *Senior Manager, DevOps & Cloud Engineering for AI Applications* — Case 1
> (CI/CD Pipeline for a GenAI RAG Microservice, Build & Release).

---

## 1. The idea in one paragraph

Three things ship independently, and each has its own build, deploy and rollback story:

| Component | What it is | Artifact | Rollback |
| --- | --- | --- | --- |
| `rag-api` | FastAPI service — retrieves context, calls Bedrock, answers | container image digest | blue/green traffic shift back (prod) / circuit breaker (dev) |
| `rag-ingest` | one-off ECS task — chunks + embeds the corpus | container image digest | re-run previous release |
| **the index** | LanceDB dataset on S3 under an immutable version prefix | `indexes/v{N}-{gitsha}/` | flip an SSM pointer back — seconds, no rebuild |

Treating **the vector index as a first-class release artifact** — versioned, gated, promoted and
rolled back exactly like the container image — is the central idea of this repo. A GenAI service's
worst failure mode is *"healthy, fast, and quietly wrong"*, which no health check can see. So the
index gets the same release discipline the code gets.

---

## 2. Architecture

```
 GitHub Actions (3 OIDC roles, zero long-lived keys)
 ┌───────────────────────────────────────────┐
 │ ci.yml       → rag-role-cipipeline         │ fmt/lint/test/plan  (read-only)
 │ release.yml  → rag-role-releasepipeline    │ build + push image  (ECR write only)
 │ deploy.yml   → rag-role-deploymentpipeline │ terraform apply + deploy
 │ index.yml    → rag-role-deploymentpipeline │ build + gate + promote index
 └───────────────────────────────────────────┘
            │  push image                       │  deploy release vX.Y.Z
            ▼                                   ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │ AWS ACCOUNT — us-east-1                                         │
 │   ECR · immutable tags · scan on push · deploys resolve digests  │
 │                                                                 │
 │  ┌── rag-dev-* ───────────────┐   ┌── rag-prod-* ─────────────┐  │
 │  │ own VPC / ALB / ECS / S3   │   │ own VPC / ALB / ECS / S3  │  │
 │  │ rolling + circuit breaker  │   │ CodeDeploy blue/green     │  │
 │  │ SSM /rag/dev/*             │   │ canary 10%/5m → 100%      │  │
 │  │ auto-rollback on failure   │   │ SSM /rag/prod/*           │  │
 │  └────────────────────────────┘   │ alarm-based auto-rollback │  │
 │                                   └───────────────────────────┘  │
 └─────────────────────────────────────────────────────────────────┘
            │                                   │
            └──────────► Amazon Bedrock ◀───────┘
                 Titan Text Embeddings V2 (embed)
                 Amazon Nova Lite (generate)
              IAM scoped to exactly those model ARNs

   CloudWatch alarms ──► SNS ──► chat webhook
```

The two environments are separate stacks — separate VPCs, load balancers, index buckets, SSM
namespaces and task roles — sharing one account and one registry. Splitting them across two
accounts is a stronger blast-radius story and is the documented target state; the account boundary
is a Terraform variable rather than a rewrite. See [decisions §5](docs/decisions.md).

Full write-up: [docs/design-spec.md](docs/design-spec.md) · decisions:
[docs/decisions.md](docs/decisions.md) · operations: [docs/runbook.md](docs/runbook.md)

---

## 3. Repository layout

```
.
├── app/
│   ├── api/                  FastAPI inference service   (src/, tests/, Dockerfile)
│   ├── ingest/               corpus → chunks → embeddings → versioned index
│   └── shared/               manifest schema + Bedrock embedding client, used by both
├── infra/
│   ├── bootstrap/            run once: Terraform state bucket (the only local-state layer)
│   ├── platform/             shared, rarely changes: GitHub OIDC provider, 3 roles, ECR
│   ├── modules/              reusable Terraform modules
│   └── envs/                 thin compositions — nonprod/dev, nonprod/stage, prod
├── .github/workflows/        ci.yml · release.yml · deploy.yml · index.yml
├── pipelines/scripts/        bash implementation shared by humans and CI
├── eval/                     golden set, quality gate, per-environment thresholds
├── docs/                     design-spec.md · decisions.md · runbook.md
├── data/raw/                 15-document sample corpus
├── Makefile                  ergonomic wrapper over pipelines/scripts
└── AI_USAGE.md               AI-assistance disclosure (required by the case)
```

All three Python packages use src-layout (`app/*/src/<package>/`) with tests alongside, so imports
behave identically in the venv, in CI and inside the containers.

**Why the layers are split this way.** `bootstrap` is the only thing a human runs with admin
credentials, and it is the only thing with local state — it exists purely to create the remote
state bucket. `platform` holds what is shared across environments and changes rarely (identity,
registry). `envs/*` holds what is duplicated per environment and changes often. The blast radius of
a bad `envs/dev` apply therefore stops at dev.

**Why `pipelines/scripts` and not logic inside the workflow YAML.** The workflows are thin: they
handle identity, inputs and artifacts, then call the same script a human would call. Nothing in the
deployment path is reachable only from CI, which is what makes an incident at 2am survivable.

---

## 4. Prerequisites

| Tool | Version | Needed for |
| --- | --- | --- |
| AWS CLI | v2.15+ | bootstrap, smoke tests, index promotion |
| Terraform | ≥ 1.11 | all IaC (uses native S3 state locking — no DynamoDB table) |
| Python | 3.12 target, ≥ 3.11 to run tests locally | app + eval harness |
| Docker | any recent | local image builds (**optional** — CI builds the real artifacts) |
| Git Bash / WSL | — | running `pipelines/scripts/*.sh` on Windows |

One AWS account and **Bedrock model access enabled in `us-east-1`** for
`amazon.titan-embed-text-v2:0` and `amazon.nova-lite-v1:0`
(Bedrock console → *Model access* → *Enable specific models*). Model access is granted per account
and per region, so it is requested once here.

> Current-generation models cannot be invoked by their bare foundation-model id — they are
> reachable only through a cross-region **inference profile** such as `us.amazon.nova-lite-v1:0`.
> Confirm what your account offers with `aws bedrock list-inference-profiles`, since availability
> differs by account and region.

> **Why Nova Lite and not Claude Haiku.** Anthropic models on Bedrock require a per-account *use
> case details* form to be submitted and approved before any invocation succeeds; until then every
> call returns `ResourceNotFoundException` with that explanation in the message. A first-party
> Amazon model is invokable as soon as IAM allows it, so the default keeps the release path free of
> a console prerequisite. Switching to Claude is `-var text_model_id=us.anthropic.claude-...` and
> no code change — the point of [decisions §4](docs/decisions.md).

> Use a personal AWS account. Nothing in this repo should ever run against a corporate account.

### The zero-setup option

This repo ships a dev container, so you can skip the table above entirely:

**Code → Codespaces → Create codespace**, or locally via *Dev Containers: Reopen in Container*.

You get Python 3.12, Terraform 1.15.8, Docker, tflint, the AWS CLI and the GitHub CLI already
pinned to the versions CI uses, with dependencies installed. This is the recommended path on a
managed workstation where Docker or WSL2 cannot be installed — and it means a reviewer can run
the tests without installing anything.

Check whichever machine you are on:

```bash
bash pipelines/scripts/check_tools.sh
```

---

## 5. Quickstart

```bash
# 0. one-time, with admin credentials — creates the Terraform state bucket
bash pipelines/scripts/bootstrap.sh

# 1. one-time — GitHub OIDC provider, the 3 pipeline roles, ECR repositories
bash pipelines/scripts/platform.sh

# 2. from here on, everything runs through the pipeline
#    Actions → release.yml   (build + push a versioned image)
#    Actions → deploy.yml    (choose release + environment)
#    Actions → index.yml     (build, gate and promote an index version)
```

Local equivalents (same scripts CI runs):

```bash
make plan   ENV=dev
make deploy ENV=dev VERSION=v0.1.0
make smoke  ENV=dev
make destroy ENV=dev
```

`make` is a convenience only — every target is a one-line wrapper around `pipelines/scripts/*.sh`,
so a machine without `make` loses nothing.

---

## 6. Cost

Designed to sit near **$1/day** while running, and **$0 when destroyed**. Approximate `us-east-1`
list prices, one task per environment:

| Component | Dev up 24/7 | Both up 24/7 |
| --- | --- | --- |
| Application Load Balancer | ~$0.54/day | ~$1.08/day |
| Fargate 0.25 vCPU / 0.5 GB | ~$0.30/day | ~$0.60/day |
| S3 + ECR + SSM + CloudWatch | cents | cents |
| **Bedrock** — full corpus ingest + an eval run | **< $0.10** | **< $0.10** |
| **Total** | **~$0.85/day** | **~$1.70/day** |

The load balancer is the cost driver, not the AI. Titan embeddings for the whole corpus cost less
than a cent, and a 15-question eval run is a few cents — worth knowing before optimising the wrong
thing. Keeping prod up only for demo windows holds the average near $1/day.

- **No NAT gateway.** Tasks run in public subnets with no inbound path except the ALB security
  group, and reach Bedrock/S3/ECR over the internet gateway. A NAT gateway alone would cost more
  than everything above combined.
- 0.25 vCPU / 0.5 GB Fargate tasks; dev scales to `desired_count = 0` when idle.
- LanceDB files on S3 instead of a managed vector database — see
  [decisions §1](docs/decisions.md).
- An AWS Budget with an alert is created by the observability module, plus a token-spend alarm —
  a runaway prompt loop is an availability incident with an invoice attached.

`make destroy ENV=dev` is part of the deliverable and is verified, not assumed.

---

## 7. Documentation index

Four documents, deliberately. Anything worth writing down belongs in one of them.

| Document | Contents |
| --- | --- |
| [docs/design-spec.md](docs/design-spec.md) | The full write-up: problem, architecture, release paths, eval gate, security, observability, scope |
| [docs/decisions.md](docs/decisions.md) | Six decisions, each with what it costs as well as what it buys |
| [docs/runbook.md](docs/runbook.md) | Deploy, both rollbacks, Bedrock failure triage, cost control, escalation |
| [AI_USAGE.md](AI_USAGE.md) | Which parts were AI-assisted, and nine corrections that reached real AWS |
