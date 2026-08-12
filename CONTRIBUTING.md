# Contributing

This repo is a case study, but it is structured the way a real platform repo should be: another
engineer should be able to add a module or a pipeline stage without reading every file first.

## Branching and commits

- `main` is protected: no direct pushes, PR + review + green checks required.
- Branch names: `feat/…`, `fix/…`, `chore/…`, `docs/…`.
- [Conventional Commits](https://www.conventionalcommits.org/): `feat(api): return active index version from /version`.
  Scopes in use: `api`, `ingest`, `infra`, `ci`, `eval`, `docs`.
- Squash-merge. The release version is derived from tags, so the commit subject on `main` is what
  ends up in the release notes.

## The PR gate

`ci.yml` runs two independent legs so a Terraform-only change is not blocked on Python and vice
versa:

| Leg | Checks |
| --- | --- |
| app | `ruff` · `black --check` · `pytest` (Bedrock stubbed) · `hadolint` · `docker build` (no push) · Trivy fs + image · CodeQL |
| infra | `terraform fmt -check` · `validate` · `tflint` · `plan` for **both** environments, posted as a PR comment |

Run the same thing locally before pushing:

```bash
make ci
```

Never weaken a check to make a build green. If a check is wrong, fix the check in its own PR and
say so in the description.

## Adding a Terraform module

1. `infra/modules/<name>/` with `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `README.md`.
2. Modules declare **no** provider blocks and **no** backend — compositions own those. This is what
   lets the same module serve dev and prod without a fork.
3. Every input gets a `description` and a `type`. Anything environment-shaped gets a default only
   if the safe value is the same in prod.
4. Wire it into `infra/envs/dev` first, prove the plan, then `infra/envs/prod`.

## Adding a pipeline step

Put the logic in `pipelines/scripts/` as a bash function or script and call it from the workflow.
A step that only exists inside workflow YAML cannot be run by a human during an incident, so it
does not belong there.

## Tests

- Every behaviour change ships with its test in the same PR.
- Bedrock is never called from unit tests — it is stubbed at the boundary (`botocore.Stubber`).
- The eval harness in `eval/` is a **release gate**, not a unit test. It runs against a deployed
  environment and is allowed to be slow.

## Documentation

- A decision with a defensible alternative gets an ADR in `docs/adr/`, numbered, 1 page, in the
  same PR that implements it.
- Operational changes (a new alarm, a new rollback path) update `docs/runbook.md` in the same PR.
- AI-assisted work is logged in `AI_USAGE.md`.
