# ADR-0003 — Deploy strategy differs per environment: rolling in dev, blue/green in stage and prod

**Status:** accepted · **Date:** 2026-08 · **Decides:** how new task definitions reach traffic

## Context

ECS offers two deployment controllers. Choosing one globally means either paying blue/green's cost
in an environment that does not need it, or accepting rolling updates in an environment that cannot
tolerate a partial bad rollout.

## Decision

The deployment controller is a per-environment variable.

| | dev | stage | prod |
| --- | --- | --- | --- |
| Controller | `ECS` (rolling) | `CODE_DEPLOY` | `CODE_DEPLOY` |
| Traffic shift | in place, one task | 10% canary → 5 min bake → 100% | 10% canary → 5 min bake → 100% |
| Rollback trigger | deployment circuit breaker | CloudWatch alarm on the *new* target group | CloudWatch alarm on the *new* target group |
| Approval | none | none | GitHub environment approval |
| Tasks | 1 | 2 | 2 |

**Dev uses rolling updates with the deployment circuit breaker.** Dev's purpose is fast feedback,
and a second target group doubles the ALB rules and the cost for an environment where a minute of
degradation is free. The circuit breaker already restores the previous task set automatically when
a new one never becomes healthy, which covers the failure mode dev actually produces: a task that
will not start.

**Stage and prod use CodeDeploy blue/green.** The failure the circuit breaker cannot catch is a
task that *starts healthy and then serves badly* — the characteristic RAG failure, where the
container is up, `/healthz` is green, and every answer is wrong or every Bedrock call throttles.
Blue/green with alarms on the new target group catches that, because the alarm watches the new
task set's error rate and latency specifically while only 10% of traffic is exposed to it.

The alarms wired to the deployment group are 5xx rate, target response time, and unhealthy host
count on the *replacement* target group. Any one in ALARM during the bake aborts the deployment and
shifts traffic back to the original task set.

## Consequences

- Dev is cheap and fast; prod is safe and slower. The difference is a variable, not a fork of the
  module, so both paths are the same Terraform code and stage genuinely rehearses prod.
- Stage exists specifically to exercise the blue/green path before prod does. A blue/green
  deployment that has never run is not a rollback story.
- Two extra target groups and a CodeDeploy application per blue/green environment — accepted cost.
- Rolling and blue/green fail differently, so the runbook documents them separately.
