# Runbook

Operational procedures for the RAG service. Written to be followed at 2am by someone who did not
build it.

Every command below runs the same script the pipeline runs. Nothing in the recovery path is
reachable only from a GitHub workflow.

```bash
export ENV=dev            # or prod
export AWS_REGION=us-east-1
```

---

## 0. First question: is it the service or the index?

```bash
curl -s "$(make api-url)/healthz" | jq
```
```json
{
  "status": "ok",
  "env": "dev",
  "release": "v0.6.0",
  "git_sha": "c752f35",
  "index_version": "v1-eef8737",
  "embed_model_id": "amazon.titan-embed-text-v2:0",
  "text_model_id": "us.amazon.nova-lite-v1:0"
}
```

`release` and `index_version` move independently and have independent rollbacks. Read both before
deciding anything. `index_version` is what the running process actually loaded, not what is
configured — if it disagrees with SSM, the tasks have not restarted since the last promotion.

| Symptom | Likely domain | Go to |
| --- | --- | --- |
| 5xx, tasks restarting, latency spike after a deploy | service | §1 |
| answers wrong or irrelevant, no deploy happened | index | §2 |
| `503 index_unavailable` | index | §2.3 |
| `503 embedding_model_mismatch` | index | §2.4 |
| `401 unauthorized` | caller is missing or using a stale API key | §0.1 |
| `429 model_throttled` | Bedrock capacity | §3 |
| `502 model_unavailable` | Bedrock config or access | §4 |

### 0.1 Getting the API key

`/ask` requires an `x-api-key` header. `/healthz` does not, so triage works without it.

```bash
make api-key ENV=$ENV
```

Reads it from Secrets Manager. It is never printed by the pipelines — `deploy.yml` and `index.yml`
mask it before it can reach a log.

```bash
curl -s -X POST "$(make api-url)/ask" \
  -H "x-api-key: $(make api-key)" \
  -H 'content-type: application/json' \
  -d '{"question":"What does the relief crew find at the lighthouse?"}'
```

To rotate: write a new value to the secret, then force a rolling restart so tasks pick it up. The
old key stops working the moment the new tasks are serving.

---

## 1. Service rollback

### 1.1 Dev — rolling update

**Redeploy the previous release. Do not wait for the circuit breaker.**

```bash
gh workflow run deploy.yml -f version=v0.5.0 -f environment=dev
```

This is not a rebuild. `deploy.sh` resolves `v0.5.0` to the digest already in ECR, so the bytes
that ran before are the bytes that run again. `deploy.yml` also does this for you automatically
when a deploy fails, which is dev's real rollback path.

**Why not the circuit breaker.** It is enabled with `rollback = true`, but at `desired_count = 1`
it rarely fires: `minimumHealthyPercent = 100` keeps the old healthy task running, and
`resetOnHealthyTask` resets the failure counter every time that task is seen. A forced deployment
with an unpullable image sat `IN_PROGRESS` for thirty minutes without reversing. Dev stayed up the
whole time — the old task keeps serving — so this is a stuck deployment, not an outage. Treat the
circuit breaker as a backstop and reach for the redeploy above.

If a deployment is stuck this way and you want it cleared immediately:

```bash
aws ecs update-service --cluster rag-dev-cluster --service rag-dev-api \
  --task-definition rag-dev-api:<previous-revision>
```

### 1.2 Prod — gated blue/green

**If the deployment is still in progress,** it may already be reversing itself. Check what stage it
reached and what the gate said:

```bash
arn=$(aws ecs list-service-deployments \
  --cluster rag-prod-cluster --service rag-prod-api \
  --query 'serviceDeployments[0].serviceDeploymentArn' --output text)

aws ecs describe-service-deployments --service-deployment-arns "$arn" \
  --query 'serviceDeployments[0].[status,lifecycleStage,lifecycleHookDetails]'
```

A hook status of `FAILED` at `POST_TEST_TRAFFIC_SHIFT` means the gate rejected the release and ECS
is rolling back on its own — **no production traffic ever reached it**. The reason is in the gate's
log, which names the failing cases:

```bash
aws logs tail /aws/lambda/rag-prod-deployment-gate --since 30m
```

To stop a deployment immediately rather than wait:

```bash
aws ecs stop-service-deployment --service-deployment-arn "$arn" --stop-type ROLLBACK
```

**If the deployment already completed,** re-run `deploy.yml` at the previous version. That is a
normal blue/green release in the other direction: the old digest is staged, the gate judges it, and
only then does traffic move. The gate passing is near-certain — it passed when that version shipped
— but it is not skipped, because "roll back to something broken" is a real incident.

**Terraform state after an automatic rollback.** When ECS reverses a deployment itself, the service
returns to the previous release but Terraform still records the new one. `deploy.yml` handles this:
its rollback step redeploys the previous version by digest, which makes state match what is
actually serving. If that step also failed, run it by hand — otherwise the next plan shows no drift
and quietly re-applies the bad image.

### 1.3 Verify

```bash
make smoke ENV=$ENV VERSION=v0.5.0
```

`smoke.sh` fails if `/healthz` reports anything other than the expected release. Note that during a
rolling update the ALB round-robins between old and new tasks for several minutes — a single curl
that returns the old version is not evidence that the rollback failed. `smoke.sh` retries.

---

## 2. Index operations

### 2.1 What is live, and what could I go back to?

```bash
make index-status ENV=$ENV
```

Prints the promoted version, the previous version, and every version in the bucket with its
manifest summary.

### 2.2 Roll back the index

```bash
make rollback-index ENV=$ENV
```

Writes the previous version to `/rag/<env>/active_index_version` and forces a rolling restart so
running tasks reload. Recovery time is task restart time — typically under two minutes. The bad
index is not deleted; it stays in S3 for diagnosis.

Equivalent from the pipeline: `index.yml`, action `rollback`.

> The eval gate deliberately does **not** run on `rollback`. Rolling back is the remedy; making it
> wait for a gate that may itself be failing turns a two-minute recovery into an outage.

### 2.3 `503 index_unavailable`

The task could not load an index. In order of likelihood:

1. **No index has ever been promoted.** `/healthz` reports `index_version: "none"`. Run
   `index.yml` with `build-and-promote`.
2. **The SSM parameter names a version that is not in S3.** Compare
   `make index-status` output against `aws s3 ls s3://rag-<env>-index/indexes/`.
3. **The task role lost read access to the bucket.** Check
   `/ecs/rag-<env>-api` for `AccessDenied`.

### 2.4 `503 embedding_model_mismatch`

The index was built with a different embedding model or dimension count than the API is configured
to use. This is a guard, not a bug: serving that index would produce confidently wrong retrieval
rather than an error.

```bash
aws s3 cp "s3://rag-$ENV-index/indexes/<version>/manifest.json" - | jq
```

Either promote an index built with the API's current embedding model, or change
`embed_model_id` back and redeploy. Changing the embedding model **requires a full index rebuild**;
there is no in-place migration.

### 2.5 Build and promote a new index

```bash
make seed-corpus ENV=$ENV          # only if the corpus changed
gh workflow run index.yml -f environment=$ENV -f action=build-and-promote
```

The pipeline runs the ingestion job as a one-off ECS task, reads the published version from its log
stream, promotes it, smoke-tests, then runs the eval gate. A failed gate leaves the new index
promoted and fails loudly — see §2.2 to revert.

---

## 3. `429 model_throttled` — Bedrock capacity

Per-account, per-region, per-model. The client already retries with adaptive backoff, so a 429
reaching the caller means sustained throttling, not a blip.

1. Check the `bedrock.throttled` count in the dashboard. A step change usually means a load
   increase, not a config change.
2. Short term: reduce `top_k` (smaller prompts, fewer tokens per call) or reduce task count to shed
   load deliberately rather than randomly.
3. Medium term: request a quota increase for the model in `us-east-1`, or switch to a model with
   more headroom — one Terraform variable, per ADR-0004.

Do **not** raise the retry count. Retrying harder into a throttle amplifies it.

---

## 4. `502 model_unavailable` — Bedrock configuration or access

The error code alone is not enough. The provider's message is logged and is the only thing that
distinguishes causes:

```bash
aws logs filter-log-events \
  --log-group-name "/ecs/rag-$ENV-api" \
  --filter-pattern "bedrock.client_error" \
  --start-time $(( ($(date +%s) - 900) * 1000 )) \
  --query 'events[].message' --output text | jq -r .error_message
```

| Message contains | Cause | Fix |
| --- | --- | --- |
| `use case details have not been submitted` | provider requires an out-of-band console form (Anthropic does) | submit it, or switch model — see ADR-0004 |
| `don't have access to the model` | model access not enabled for the account/region | Bedrock console → Model access |
| `inference profile` / `not found` | a bare foundation-model id was configured where a cross-region profile id is required | use the `us.*` profile id from `aws bedrock list-inference-profiles` |
| `ValidationException` on sampling params | provider rejects the parameter combination (Anthropic rejects `temperature` + `topP` together) | send one sampling control |

This table exists because every one of these was hit during the build, and the error code alone
sent the investigation the wrong way each time. Logging `error_message` on the failure path was the
change that made diagnosis take seconds.

---

## 5. Cost control

Dev is the only environment expected to run continuously, at roughly $0.85/day (Fargate task, ALB,
NAT-free public subnets, negligible S3 and Bedrock).

**Scale dev to zero without destroying it:**

```bash
aws ecs update-service --cluster rag-dev-cluster --service rag-dev-api --desired-count 0
```

The ALB still costs ~$0.60/day. To stop that too, destroy the environment — state is remote and
the index bucket is versioned, so `make deploy` rebuilds it:

```bash
make destroy ENV=dev
```

A monthly budget alarm at $20 is created by `bootstrap.sh` and emails on 80% actual and 100%
forecast. If it fires, check `bedrock.tokens` in the dashboard first — a runaway prompt is the only
component here with an unbounded cost curve, which is why `max_output_tokens` is capped in config
rather than left to the model.

---

## 6. Escalation

| Situation | Action |
| --- | --- |
| prod down, cause unknown | roll back the service (§1.2), then the index (§2.2), in that order — service rollback is faster to verify |
| both rolled back and still down | the fault is in shared infrastructure: ALB, VPC, or Bedrock regional availability |
| eval gate failing but the service is healthy | not an outage. Leave it deployed in dev, revert in prod, and investigate with the uploaded `eval-report.json` |
