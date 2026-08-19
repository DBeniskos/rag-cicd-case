# rag-cicd-case

CI/CD for a question answering (RAG) service on AWS.

## 1. What this is

This project runs a small question answering service on AWS, plus the whole delivery pipeline
around it. The service takes a question, finds matching text in a set of documents, and asks an
Amazon Bedrock model to answer using only that text. The AI part is kept simple on purpose. The
real work here is the build, test, release, deploy and rollback process, and in particular how a
bad release gets caught and reversed before any user sees it.

Three things ship separately, and each one is versioned and can be rolled back on its own:

| Part | What it is | Version looks like | How you roll it back |
| --- | --- | --- | --- |
| `rag-api` | The web service that answers questions | `v0.21.0` (container image) | Deploy the previous version |
| `rag-ingest` | A one-off job that builds the search index | `v0.21.0` (container image) | Deploy the previous version |
| The index | The searchable copy of the documents, stored on S3 | `v2-6e21075` | Point at the older index, no rebuild |

The reason the index is treated as a release artifact is simple. A RAG service can be healthy, fast
and still give wrong answers, because the documents behind it changed. A health check cannot see
that. So the index gets the same versioning, the same quality gate and the same rollback path as
the code.

---

## 2. Requirements

Install these before you start.

| Tool | Version | Why you need it |
| --- | --- | --- |
| Git | any recent | Cloning the repo |
| AWS CLI | v2.15 or newer | Setup, smoke tests, index promotion |
| Terraform | 1.11 or newer (CI uses 1.15.8) | All infrastructure |
| Python | 3.11 or newer (containers use 3.12) | Running tests and the eval harness locally |
| Bash | Git Bash or WSL on Windows | The scripts in `scripts/` are bash |
| Make | optional | Shortcut commands. Everything works without it |
| Docker | optional | Local image builds. CI builds the real images |

Python libraries are installed from requirements files, you do not install them by hand:

- API: `fastapi`, `uvicorn`, `pydantic`, `pydantic-settings`, `boto3`, `structlog`, `lancedb`
- Ingest: `boto3`, `pydantic`, `pydantic-settings`, `structlog`, `lancedb`, `pyarrow`
- Dev tools: `pytest`, `pytest-cov`, `ruff`, `black` (see `requirements-dev.txt`)

You also need:

- An AWS account you own. Do not use a corporate account.
- Bedrock model access enabled in `us-east-1` for `amazon.titan-embed-text-v2:0` and
  `amazon.nova-lite-v1:0`. You enable this in the Bedrock console under Model access.
- A GitHub repository, because the pipeline runs on GitHub Actions.

Check your machine has what it needs:

```bash
bash scripts/check_tools.sh
```

Two notes on Bedrock that cost time if you miss them:

- Newer models cannot be called by their plain model id. They need a cross region inference
  profile, which is why the text model id is `us.amazon.nova-lite-v1:0` and not
  `amazon.nova-lite-v1:0`. Run `aws bedrock list-inference-profiles` to see what your account has.
- Claude models need an extra approval form per account before any call works. Nova Lite works as
  soon as IAM allows it. You can switch models later with a Terraform variable, no code change.

---

## 3. Setup

### 3.1 Clone and install locally

```bash
git clone https://github.com/DBeniskos/rag-cicd-case.git
cd rag-cicd-case

python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate

pip install -r requirements-dev.txt
pip install -r app/api/requirements.txt
pip install -r app/ingest/requirements.txt
```

Check it works:

```bash
make ci        # or: python -m ruff check . && python -m black --check . && python -m pytest
```

This runs the same checks the pull request gate runs. Nothing here touches AWS.

### 3.2 Create the AWS foundations

Run these two once per account, with admin credentials on your own machine. Everything after this
runs through the pipeline.

```bash
export AWS_PROFILE=your-profile
export AWS_REGION=us-east-1

bash scripts/bootstrap.sh     # S3 bucket for Terraform state, plus a monthly budget alert
bash scripts/platform.sh      # GitHub OIDC provider, 3 pipeline roles, 2 ECR repositories
```

`bootstrap.sh` is the only part that keeps Terraform state on your laptop, because it is what
creates the bucket that holds all the other state. It also writes `infra/backend.hcl`, which is
gitignored because it holds your account id.

`platform.sh` prints the values you need for GitHub at the end.

### 3.3 Configure GitHub

Set these as repository variables (Settings, Secrets and variables, Actions, Variables tab):

| Variable | Example |
| --- | --- |
| `AWS_REGION` | `us-east-1` |
| `TF_STATE_BUCKET` | `rag-tfstate-<account-id>` |
| `ECR_REGISTRY` | `<account-id>.dkr.ecr.us-east-1.amazonaws.com` |
| `AWS_CI_ROLE_ARN` | ARN of `rag-role-cipipeline` |
| `AWS_RELEASE_ROLE_ARN` | ARN of `rag-role-releasepipeline` |
| `AWS_DEPLOY_ROLE_ARN` | ARN of `rag-role-deploymentpipeline` |

Set this as a repository secret (Secrets tab, not Variables):

| Secret | Why it is a secret |
| --- | --- |
| `ALERT_EMAIL` | The address that receives alarm and rollback emails. It is a secret and not a variable because Terraform prints variables into the Actions log, and this repo is public |

Then create two GitHub environments called `dev` and `prod`. Add a required reviewer on `prod`.
That is what makes a production deploy wait for a human.

### 3.4 Upload the documents

```bash
ENV=dev bash scripts/seed_corpus.sh
```

This uploads `data/raw/sample_movie_plots.csv`, a 15 document sample, to the environment's S3
bucket. You can pass your own CSV file as an argument instead.

---

## 4. How to run it, and what to expect

Everything runs from the GitHub Actions tab. Run the workflows in this order the first time.

**Step 1. Build a release.** Actions, `release`, Run workflow, version `v0.1.0`.

Builds both container images, scans them, writes a software bill of materials, and pushes them to
ECR. Takes about 2 minutes. You get a summary table with the version, commit and image digest.

**Step 2. Deploy to dev.** Actions, `deploy`, version `v0.1.0`, environment `dev`.

Applies Terraform, deploys the release, waits for ECS, runs a smoke test, then runs the quality
gate. First run takes about 10 minutes because it creates a VPC and a load balancer. Later runs
take 2 to 3 minutes.

**Step 3. Build and promote an index.** Actions, `index`, environment `dev`, action
`build-and-promote`.

Runs the ingest job as a one-off ECS task, which reads the CSV, splits it into chunks, creates
embeddings with Bedrock, and writes a versioned index to S3. Then it points the environment at that
version and restarts the service. Takes about 5 minutes.

**Step 4. Check it works.**

```bash
make api-url ENV=dev
curl http://<that-url>/healthz
```

Expected:

```json
{
  "status": "ok",
  "env": "dev",
  "release": "v0.1.0",
  "git_sha": "abc1234",
  "index_version": "v1-abc1234",
  "embed_model_id": "amazon.titan-embed-text-v2:0",
  "text_model_id": "us.amazon.nova-lite-v1:0"
}
```

If `index_version` is `none`, no index has been promoted yet. Go back to step 3.

Now ask a question. `/ask` needs an API key, which lives in Secrets Manager:

```bash
make api-key ENV=dev
```

```bash
curl -X POST http://<url>/ask \
  -H "content-type: application/json" \
  -H "x-api-key: <the-key>" \
  -d '{"question":"What does the relief crew find in the lighthouse keeper log?"}'
```

Expected: an answer built only from the documents, with the passages it used, the index version,
the model, latency and token counts.

Ask something outside the documents and it refuses on purpose:

```json
{ "answer": "I don't know based on the indexed documents." }
```

That refusal is a feature, not a bug. It is measured by the quality gate.

**Step 5. Deploy to prod.** Same as step 2 with environment `prod`. It waits for your approval,
then uses a different and slower deployment method, described in section 7.

### Local commands

These call the same scripts the pipeline calls.

```bash
make plan     ENV=dev                  # terraform plan
make deploy   ENV=dev VERSION=v0.1.0   # full deploy
make smoke    ENV=dev                  # check what is being served
make eval     ENV=dev                  # run the quality gate
make api-url  ENV=dev
make api-key  ENV=dev
make index-status ENV=dev              # which index is live, and the history
make destroy  ENV=dev                  # tear the environment down
make help                              # list every target
```

---

## 5. The application

Three Python packages. All use a `src/` layout with tests beside them, so imports behave the same
in a virtualenv, in CI and inside the containers.

### rag-api

The web service. Python 3.12, FastAPI, running under uvicorn on ECS Fargate behind a load balancer.

| Endpoint | Method | Auth | What it does |
| --- | --- | --- | --- |
| `/healthz` | GET | none | Reports release, git commit, index version and the two model ids. The load balancer uses it as a health check |
| `/ask` | POST | `x-api-key` header | Answers a question from the documents |

How a request is handled:

1. On startup the service reads an SSM parameter to learn which index version is live, downloads
   that index from S3 to local disk, and checks the index manifest. If the index was built with a
   different embedding model than the service uses, it refuses to start. That mismatch would
   silently return nonsense rankings otherwise.
2. A question comes in. The service turns it into a vector with Bedrock Titan Text Embeddings V2.
3. It searches the LanceDB index on local disk using cosine similarity and takes the top matches.
4. It sends those passages plus the question to Amazon Nova Lite through the Bedrock Converse API,
   with a prompt that says to answer only from the passages and to say "I don't know based on the
   indexed documents" otherwise.
5. It returns the answer, the passages used, the index version, latency and token usage.

Error handling maps to real status codes: 401 for a bad key, 429 when Bedrock throttles, 502 when
the model fails, 503 when there is no usable index.

### rag-ingest

A one-off job, not a server. Same base image style, Python 3.12. It downloads the CSV from S3,
splits documents into chunks, creates embeddings with the same Titan model the API uses, builds a
LanceDB table, and uploads it to `indexes/v{N}-{git-sha}/` on S3 with a `manifest.json` next to it.

The manifest records the index version, the embedding model, the vector size, a SHA256 hash of the
corpus, the document and chunk counts, the git commit and the build time. That manifest is what
makes an answer traceable back to exact data.

The job prints the new version to stdout, and the workflow reads it from the logs to know what to
promote.

### rag-shared

Shared code used by both, so they cannot drift apart: the manifest format, and the Bedrock
embedding client. If the API and the ingest job embedded text differently, retrieval would quietly
degrade and nothing would fail loudly.

### The index format

LanceDB files on S3, not a managed vector database. For a corpus this size it is a few megabytes,
search happens in the task with no network hop, and there is no cluster to pay for or run. It stops
working somewhere around a few million vectors, and the write up in `docs/decisions.md` says what
to move to at that point.

---

## 6. AWS services used

Everything is in one account, in `us-east-1`, and all of it is created by Terraform except the
account itself.

| Service | What it is used for |
| --- | --- |
| ECS Fargate | Runs the API as a service, and the ingest job as a one-off task. No servers to patch |
| Application Load Balancer | Public entry point. In prod it has a second listener on port 8080 used for testing a new version before it takes traffic |
| ECR | Stores the two container images. Tags are immutable and images are scanned on push |
| S3 | Terraform state, the document corpus, and the versioned indexes. Versioning and encryption on |
| SSM Parameter Store | Holds which index version is live, at `/rag/{env}/active_index_version`. The parameter history is also the audit trail of every promotion |
| Secrets Manager | Holds the API key for `/ask`. It is generated by Terraform and never written to the repo or the logs |
| Bedrock | Titan Text Embeddings V2 for vectors, Nova Lite for answers. IAM is scoped to those exact model ARNs |
| Lambda | The deployment gate. ECS calls it mid deploy to score the new version before traffic moves |
| CloudWatch Logs | Log groups for the API, the ingest job and the gate |
| CloudWatch Alarms | 5xx count, p95 latency and p99 latency, per target group |
| EventBridge | Catches the ECS event that fires when a deployment is reversed, and sends it to SNS |
| SNS | One topic per environment, `rag-{env}-alerts`, with an email subscription |
| IAM | Three pipeline roles using OIDC, plus task roles. No long lived AWS keys exist anywhere |
| VPC | One per environment, with public subnets and no NAT gateway |
| AWS Budgets | A monthly budget with an email alert, created during bootstrap |

The two environments are completely separate: their own VPC, load balancer, cluster, index bucket,
secret, SSM namespace and IAM roles. They share the account and the image registry.

There is no NAT gateway on purpose. Tasks sit in public subnets with no inbound route except
through the load balancer security group, and reach Bedrock, S3 and ECR through the internet
gateway. A NAT gateway alone would cost more than everything else in this project combined.

### Terraform layout

```
infra/
  bootstrap/   Run once with admin rights. Creates the state bucket and the budget.
               The only layer with local state, because it creates the bucket the rest use.
  platform/    Run once. GitHub OIDC provider, the 3 pipeline roles, the 2 ECR repositories.
  modules/     Reusable pieces.
  envs/dev     Small files that wire the modules together for one environment.
  envs/prod
```

The seven modules:

| Module | Creates |
| --- | --- |
| `network` | VPC, internet gateway, public subnets, route tables, security groups |
| `ecs-service` | Cluster, task definition, service, load balancer, listeners, target groups, alarms, and the EventBridge rule for failed deployments |
| `ingest-task` | Task definition, log group and IAM role for the one-off ingest job |
| `index-store` | S3 bucket for indexes and corpus, plus the SSM pointer |
| `secret` | The generated API key in Secrets Manager |
| `deployment-gate` | The Lambda that scores a release mid deploy, and its two IAM roles |
| `environment` | Ties all of the above together, and owns the SNS topic and email subscription |

Splitting it this way means a bad change to `envs/dev` cannot damage prod, and the shared identity
and registry layer is only touched when identity or registry actually change.

---

## 7. How the CI/CD works

### The five stages

```
1. Pull request      ci.yml       lint, unit tests, image build and scan, terraform plan, CodeQL
2. Merge to main     ci.yml       the same checks again on main
3. Release           release.yml  build both images, scan, SBOM, push to ECR with a version tag
4. Deploy            deploy.yml   terraform apply, deploy the release to one environment, gate it
5. Index             index.yml    build, promote or roll back an index version
```

Stages 3, 4 and 5 are started by hand from the Actions tab. Merging a pull request does not deploy
anything. That is deliberate, so a merge and a production change are two separate decisions.

### Identity

There are no AWS access keys anywhere. GitHub Actions authenticates to AWS with OIDC, and each
workflow assumes a different role with only the permissions it needs:

| Role | Used by | Can do |
| --- | --- | --- |
| `rag-role-cipipeline` | ci.yml | Read only. Enough to run `terraform plan` |
| `rag-role-releasepipeline` | release.yml | Push to ECR. Nothing else |
| `rag-role-deploymentpipeline` | deploy.yml, index.yml | Terraform apply, deploy, promote an index |

The deploy role's trust policy is scoped to the GitHub environment, so the approval on `prod` is
what releases the AWS credentials, not just what unblocks the job.

### How a deploy actually runs

Both environments deploy the same way up to a point: resolve the image digest from the version tag,
run `terraform apply`, then wait for ECS. What differs is how the new version takes traffic.

**Dev uses a rolling update.** New tasks replace old ones in place. It is fast and cheap. The
quality gate runs after the deploy, because there is no second endpoint to test against first.

**Prod uses blue/green with a gate before any traffic moves.** ECS starts the new version as a
second task set, reachable only on the test listener on port 8080. Before shifting production
traffic, ECS calls a Lambda. That Lambda runs the full golden set against the new version on the
test port and returns pass or fail. On fail, ECS reverses the deployment and no production traffic
ever reaches it. On pass, traffic moves to 100 percent and there is a 5 minute bake period with
alarms watching.

A prod deploy takes about 9 to 10 minutes because of the gate and the bake. That is the price of
not shipping a bad answer.

### Rollback

There are three rollback paths, and all three have been tested by deliberately breaking things.

| What went wrong | What happens | How long |
| --- | --- | --- |
| Bad release reaches prod | The gate fails it before traffic moves. ECS reverses the deployment | Verdict in about 10 seconds |
| Any deploy job fails | The `Roll back` step in deploy.yml redeploys the previous version | 2 to 3 minutes in dev |
| Bad index | Point the SSM parameter at the previous version and restart | About 2 minutes in dev, about 9 in prod |

The rollback step in `deploy.yml` matters for a second reason. When ECS reverses a deployment by
itself, the service goes back to the old version but Terraform state still records the new one. The
next plan would show no drift and quietly re-apply the bad image. Redeploying the previous version
by digest puts state back in line with what is actually running.

One honest note. Dev also has the ECS deployment circuit breaker enabled, but at one task it does
not fire, because `minimumHealthyPercent` is 100 so the old healthy task is never stopped, and the
failure counter resets every time that healthy task is seen. It stays enabled as a backstop, but
the pipeline rollback step is what actually recovers dev. This is written up in `docs/decisions.md`.

### Notifications

Each environment has an SNS topic, `rag-{env}-alerts`, with your `ALERT_EMAIL` subscribed. You get
an email when:

- Any CloudWatch alarm goes into ALARM, and again when it clears. The alarms are 5xx count, p95
  latency and p99 latency.
- ECS reverses a deployment. An EventBridge rule watches for the `SERVICE_DEPLOYMENT_FAILED` event
  and publishes a message naming the service and the reason.

`ALERT_EMAIL` must be passed on every Terraform apply, including the rollback step. If it is
missing on one apply, Terraform removes the subscription and alerting silently switches off. AWS
also discards an email subscription that is never confirmed after 3 days, so confirm the email when
it arrives.

---

## 8. The quality gate

This is what stops a bad release. `eval/run_eval.py` sends a fixed set of questions to a running
service and scores the answers.

`eval/golden_set.jsonl` has 18 cases: 15 questions whose answers are in the documents, and 3
questions that are not, which the service is supposed to refuse.

| Metric | What it means |
| --- | --- |
| `recall_at_k` | How often the right document was retrieved |
| `answer_match_rate` | How often the answer contained the expected term |
| `refusal_rate` | How often an out of scope question was correctly refused |
| `error_rate` | How often a call failed or returned something malformed |
| `p95_latency_ms` | 95th percentile response time |

Thresholds come from `eval/thresholds.toml` and differ by environment:

| Threshold | dev | prod |
| --- | --- | --- |
| `recall_at_k` minimum | 0.90 | 0.90 |
| `answer_match_rate` minimum | 0.70 | 0.80 |
| `refusal_rate` minimum | 1.00 | 1.00 |
| `error_rate` maximum | 0.00 | 0.00 |
| `p95_latency_ms` maximum | 20000 | 10000 |

Dev is more forgiving on answer quality and latency because a cold task is slower and dev is for
fast feedback. Prod is not.

The same harness runs in three places, so they can never disagree on what good means: locally with
`make eval`, in the deploy and index workflows, and inside the gate Lambda.

Why this exists rather than just a health check: a release once passed 106 unit tests, ruff, black,
CodeQL and three Terraform plans, returned HTTP 200 to everything, retrieved the correct documents
every time, responded in 754ms, and answered almost nothing. The gate caught it on
`answer_match_rate` at 7 percent against a floor of 80. No health check can see that failure.

---

## 9. GitHub Actions

| Workflow | Runs when | Inputs | What it does |
| --- | --- | --- | --- |
| `ci.yml` | Every pull request and every push to main | none | Lint, format check, unit tests with coverage, Dockerfile lint, image build, Trivy scan, `terraform fmt` and `validate` and `plan` for all three layers, CodeQL. Posts the plan as a PR comment |
| `release.yml` | Manual, or pushing a `v*` tag | `version` | Builds both images, refuses if the version already exists in ECR, scans with Trivy, writes an SBOM, pushes with a version tag and a commit tag, records the digest |
| `deploy.yml` | Manual | `version`, `environment` | Applies Terraform, deploys the release, waits for ECS, smoke tests, runs the quality gate, rolls back if anything fails |
| `index.yml` | Manual | `environment`, `action`, `index_version` | Builds, promotes, rolls back or reports on an index version |

`index.yml` actions:

- `build-and-promote` runs the ingest job, then points the environment at the new index
- `promote-existing` points at an index that already exists, needs `index_version`
- `rollback` flips the pointer back to the previous version
- `status` prints the current version and the promotion history

The required checks on the main branch are `app · lint, test, image`, `infra · gate` and
`security · codeql`. The infra gate is a small job that waits for the per layer plan jobs, so the
required check name does not change when an environment is added.

Both `deploy.yml` and `index.yml` use GitHub environments, so a `prod` run pauses for approval.

---

## 10. Scripts

The workflows are thin. They handle credentials, inputs and artifacts, then call the same bash
script a human would run. Nothing in the deployment path is reachable only from CI, which is what
makes it usable during an incident.

| Script | What it does | Run by |
| --- | --- | --- |
| `check_tools.sh` | Checks the local machine has git, terraform and aws, and warns about optional tools | Human |
| `bootstrap.sh` | Creates the Terraform state bucket and the monthly budget alert. Writes `infra/backend.hcl` | Human, once |
| `platform.sh` | Creates the GitHub OIDC provider, the three pipeline roles and the ECR repositories. Prints the GitHub values you need | Human, once |
| `seed_corpus.sh` | Uploads the corpus CSV to the environment's S3 bucket | Human |
| `deploy.sh` | Resolves image digests from the version tag, applies Terraform, waits for the deployment, smoke tests. Records the previous release first so a rollback knows where to go | deploy.yml, human |
| `wait_for_deployment.sh` | Watches an ECS deployment and prints what is happening: lifecycle stages, the gate verdict, traffic weights, alarms and reversals. Uses a 10 minute timeout for rolling and 60 minutes for blue/green | deploy.sh |
| `smoke.sh` | Polls `/healthz` until the service is up and confirms it is serving the expected release and index. Retries, because a load balancer alternates between old and new tasks during a rolling update | deploy.sh, index.yml, human |
| `promote_index.sh` | Writes the SSM pointer and forces a new deployment so tasks reload. Also handles `--rollback` and `--status`. Refuses to promote a version that has no manifest in S3 | index.yml, human |

One thing worth knowing about `promote_index.sh --rollback`: it is a single step undo, not "go back
to the last good one". It flips to the most recent different value in the parameter history, so
running it twice returns you to where you started. To reach a specific version, name it with
`make promote-index ENV=dev VERSION=v1-abc1234`.

---

## 11. Cost

About $1 per day with dev running, about $2 with both running, and $0 when destroyed.

| Item | Dev only | Both |
| --- | --- | --- |
| Load balancer | ~$0.54/day | ~$1.08/day |
| Fargate, 0.25 vCPU and 0.5 GB | ~$0.30/day | ~$0.60/day |
| S3, ECR, SSM, CloudWatch | cents | cents |
| Bedrock, full ingest plus an eval run | under $0.10 | under $0.10 |
| Total | ~$0.85/day | ~$1.70/day |

The load balancer is the cost, not the AI. Embedding the whole corpus costs less than a cent.

To reduce cost between sessions:

```bash
aws ecs update-service --cluster rag-dev-cluster --service rag-dev-api --desired-count 0
```

To stop paying entirely, destroy the environment:

```bash
make destroy ENV=dev
```

Destroy works on dev. Prod deliberately does not: its index bucket has `force_destroy` turned off
so an accidental destroy cannot delete the corpus and the indexes. To decommission prod you have to
empty that bucket first, including old object versions, and that is a conscious act.

---

## 12. Documentation

| File | What is in it |
| --- | --- |
| [docs/design-spec.md](docs/design-spec.md) | The full write up: problem, architecture, release paths, the gate, security, observability |
| [docs/decisions.md](docs/decisions.md) | The decisions, each with what it costs as well as what it buys |
| [docs/runbook.md](docs/runbook.md) | What to do when something breaks: both rollbacks, Bedrock failures, cost control |

## 13. Repository layout

```
app/
  api/       The web service. src/, tests/, Dockerfile
  ingest/    The index builder. src/, tests/, Dockerfile
  shared/    Manifest format and the embedding client, used by both
infra/
  bootstrap/ State bucket and budget. Run once with admin rights
  platform/  OIDC provider, 3 roles, ECR. Run once
  modules/   The 7 reusable Terraform modules
  envs/      dev and prod, one small file each
.github/workflows/   ci.yml, release.yml, deploy.yml, index.yml
scripts/             The bash that both humans and CI run
eval/                Golden set, the harness, per environment thresholds
docs/                design-spec.md, decisions.md, runbook.md
data/raw/            The 15 document sample corpus
Makefile             Shortcuts over the scripts
```

## 14. A note on AI assistance

This project was built with the help of an AI coding agent, using the latest Claude models. The
idea, the architecture and the structure are mine. I decided what to build, how to split it, which
trade-offs to accept and what "done" had to mean. The agent helped me write and test it faster.

It was most useful for the repetitive parts: writing Terraform modules that follow a pattern I had
already chosen, generating test cases, and running the chaos tests that proved the rollback paths
work. Several real defects came out of that process, including a quality gate that could never
fail, alarm topics with no subscriber, and a documented recovery time that was wrong by a factor of
five. Those were found by testing the system rather than by reading the code.

Every design decision in `docs/decisions.md` is mine, and I can defend all of them. The AI wrote a
lot of the words and a lot of the HCL. It did not decide what this should be.

