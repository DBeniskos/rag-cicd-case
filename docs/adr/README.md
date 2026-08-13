# Architecture decision records

Each record states the decision, what it buys, and what it costs. A decision with no listed cost
has not been thought about hard enough.

| # | Decision | Turns on |
| --- | --- | --- |
| [0001](0001-vector-store.md) | LanceDB on S3, not OpenSearch or pgvector | rollback is a pointer write, and cost at this scale |
| [0002](0002-index-as-release-artifact.md) | The index is a versioned release artefact with its own pipeline | the index and the service fail independently, so they must roll back independently |
| [0003](0003-deploy-strategy-per-environment.md) | Rolling in dev, CodeDeploy blue/green in stage and prod | the circuit breaker cannot catch a task that starts healthy and answers badly |
| [0004](0004-converse-api.md) | Bedrock Converse API, model id as a variable | portability — which was cashed in mid-build when a provider gated the intended model |
| [0005](0005-single-account-two-stacks.md) | One account, two isolated stacks | scope, with named compensating controls |
| [0006](0006-eval-gate-is-deterministic.md) | No LLM judge in the release gate | a gate that is not reproducible gets overridden, and an overridden gate is worse than none |
