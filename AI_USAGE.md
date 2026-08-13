# AI usage disclosure

The case study explicitly allows and encourages AI assistance, and requires transparency about it.
This file is maintained as the work progresses, not reconstructed at the end.

## Tools used

| Tool | Role |
| --- | --- |
| GitHub Copilot (agent mode, Claude) | Pair-programming: scaffolding, Terraform modules, workflow YAML, docs drafting |

## How it was used

**Where AI did the typing:** boilerplate with a known shape — Terraform module skeletons,
`variables.tf` blocks, workflow YAML, Dockerfiles, docstrings, the first draft of this repo's
markdown. This is the work where an assistant is genuinely faster and the failure mode (a typo) is
caught by `terraform validate` or a linter anyway.

**Where the decisions were human:** everything in `docs/adr/`. The architecture was specified
before any code was generated — two accounts, ALB over NLB, LanceDB on S3, three OIDC roles split
by pipeline, index-as-artifact with an SSM pointer. The assistant implemented that specification;
it did not choose it.

**What was corrected.** Running log, kept honest on purpose — the interesting part of working with
an assistant is where it is wrong. Every row below is a real failure that reached a real AWS
account or a real pipeline run, not a hypothetical:

| # | What the assistant produced | What was wrong | Correction |
| --- | --- | --- | --- |
| 1 | OIDC trust policy with `sub` = `repo:DBeniskos/rag-cicd-case:pull_request` | This is the documented format, but with immutable actions enabled GitHub issues `repo:DBeniskos@156813366/rag-cicd-case@1332120918:pull_request`. Every `AssumeRoleWithWebIdentity` failed. | Diagnosed from `principalId` in a CloudTrail `lookup-events` result — not from the docs. Pinned to numeric IDs, which is *stronger* than names because names can be transferred. |
| 2 | `aquasecurity/trivy-action@0.28.0` | The tag does not exist; the action's tags are `v`-prefixed. Confidently wrong version pin. | `v0.36.0`, verified against the repository's tag list rather than assumed. |
| 3 | `terraform plan \| tee plan.txt` in a workflow step | GitHub Actions `run:` defaults to `bash -e` without `pipefail`, so a failing plan exited 0 and the gate reported green on a broken plan. | Added `shell: bash` (which sets `-o pipefail`). A gate that cannot fail is worse than no gate. |
| 4 | Matrix job names as branch-protection required checks | Matrix job names include the parameter, so the required-check name never matches and protection silently enforces nothing. | Added a stable `infra · gate` aggregation job and required that instead. |
| 5 | `ingest_image` defaulting to the API image | A one-off ECS ingestion task started `uvicorn` and ran forever instead of building an index. A default that is silently wrong is worse than a missing one. | Made the variable required, with a validation block asserting the image reference contains `rag-ingest`. |
| 6 | `/version` reporting the *configured* index version | Reported what the task was told to load, not what it actually loaded — so it would have reported success after a failed index load. | Reports `retriever.index_version`, the version genuinely in memory. |
| 7 | `inferenceConfig` with both `temperature` and `topP` | Anthropic models reject both sampling controls in one request with `ValidationException`. | Send `temperature` alone. Documented in ADR-0004 so the next person does not re-add it. |
| 8 | `anthropic.claude-3-5-haiku-20241022-v1:0` as the model id | Bare foundation-model ids are not invokable for current-generation models; they need a cross-region inference profile. | `aws bedrock list-inference-profiles` to find the real id, and IAM widened to the profile ARN *plus* the underlying model ARN in all three US regions. |
| 9 | Makefile targets calling `terraform.sh`, `eval.sh`, `destroy.sh`, `fmt.sh`, `lint.sh`, `test.sh`, `build.sh` | None of those scripts exist. Plausible-looking scaffolding that had never been run. | Rewrote the Makefile against the scripts that actually exist. **Generated code that is never executed is not code.** |

**The most useful thing the assistant did was not writing code.** After #7 was fixed, the next
failure was `ResourceNotFoundException` — a code that also fits "wrong model id", which had already
been diagnosed once. Adding the provider's `error_message` to the failure log turned a third
speculative round trip into a one-line answer: *"Model use case details have not been submitted for
this account. Fill out the Anthropic use case details form."* That is an account prerequisite no
amount of code change would have fixed. The response was to switch to `us.amazon.nova-lite-v1:0`,
which was a one-variable change precisely because of the Converse API decision in ADR-0004.

## Session log

| Date | Milestone | AI-assisted | Human-led |
| --- | --- | --- | --- |
| 2026-08-12 | M1 — scaffold, Terraform skeleton, API stub | File scaffolding, module boilerplate, README/CONTRIBUTING drafts | Layer split (bootstrap/platform/envs), no-NAT decision, scripts-not-YAML rule, naming convention |
| 2026-08-13 | M2 — platform, CI, first real deploys | Workflow YAML, IAM policy documents, bash scripts | OIDC role split by pipeline, digest-not-tag promotion, immutable-release guard |
| 2026-08-13 | M3 — index pipeline, `/ask` end to end | Ingestion job, manifest handling, retrieval module | Index versioning scheme, manifest-last upload ordering, embedding-mismatch guard |
| 2026-08-13 | M4 — eval gate, docs, ADRs | Harness implementation, golden-set drafting, ADR prose | **Rejecting LLM-as-judge for the gate** (ADR-0006), threshold levels, what the gate must refuse to do |

## Verification stance

Nothing generated is trusted because it was generated. The gates below are what actually vouch for
the code, and they are the same gates a human-written change passes:

- `terraform validate` + `tflint` + a reviewed `plan` before any apply
- `ruff` + `black` + `pytest` with Bedrock stubbed
- CodeQL and Trivy on every PR
- the golden-set eval harness before any promotion to prod
- a real deploy, a real rollback, and a real index pointer flip — screenshotted, not described
