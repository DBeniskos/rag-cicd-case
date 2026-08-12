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
an assistant is where it is wrong:

| # | What the assistant produced | What was wrong | Correction |
| --- | --- | --- | --- |
| 1 | _(log entries are added as they occur)_ | | |

## Session log

| Date | Milestone | AI-assisted | Human-led |
| --- | --- | --- | --- |
| 2026-08-12 | M1 — scaffold, Terraform skeleton, API stub | File scaffolding, module boilerplate, README/CONTRIBUTING drafts | Layer split (bootstrap/platform/envs), no-NAT decision, scripts-not-YAML rule, naming convention |

## Verification stance

Nothing generated is trusted because it was generated. The gates below are what actually vouch for
the code, and they are the same gates a human-written change passes:

- `terraform validate` + `tflint` + a reviewed `plan` before any apply
- `ruff` + `black` + `pytest` with Bedrock stubbed
- CodeQL and Trivy on every PR
- the golden-set eval harness before any promotion to prod
- a real deploy, a real rollback, and a real index pointer flip — screenshotted, not described
