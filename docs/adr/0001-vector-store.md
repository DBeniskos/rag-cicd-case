# ADR-0001 — Vector store: LanceDB on S3, not OpenSearch or a managed vector database

**Status:** accepted · **Date:** 2026-08 · **Decides:** where retrieval reads from

## Context

The service needs a vector store for a corpus in the low thousands of chunks, in a personal AWS
account, with a hard requirement that a bad index can be rolled back independently of the service.

Three options were considered.

| Option | Idle cost | Rollback story | Operational surface |
| --- | --- | --- | --- |
| Amazon OpenSearch Serverless | ~$700/mo floor (2 OCU minimum) | reindex or snapshot restore | collection, policies, capacity |
| Aurora PostgreSQL + pgvector | ~$50/mo minimum instance | schema migration or table swap | cluster, backups, connection pooling |
| **LanceDB files on S3** | **~$0.02/mo for this corpus** | **overwrite one SSM parameter** | **a bucket** |

## Decision

Store each index build as an immutable, versioned prefix in S3:

```
s3://rag-<env>-index/indexes/v3-a1b2c3d/
    manifest.json      embed model id, dimensions, chunk count, corpus hash, built-at
    passages.lance/    the table itself
```

An SSM Parameter Store value, `/rag/<env>/active_index_version`, names the version that is live.
The API reads that parameter at startup, downloads the prefix to the task's ephemeral storage, and
serves from local disk.

## Consequences

**What this buys.**

- *Rollback is a pointer write.* Promoting and rolling back are the same operation with a different
  argument, and the previous index is still in S3 untouched. Recovery is bounded by task restart
  time, not by a rebuild. This is the single property that most influenced the choice.
- *Index and service version independently.* `deploy.yml` moves the service, `index.yml` moves the
  index. Neither can be forced to move because the other did.
- *Search is in-process.* No network hop, no cluster to size, no connection pool to exhaust. p50
  retrieval is single-digit milliseconds.
- *Cost is proportional to storage*, which for this corpus is rounding error.

**What this costs, honestly.**

- *It does not scale past one node's disk and memory.* The ceiling is roughly the low millions of
  vectors. Beyond that this decision must be revisited — it is a deliberate fit to the stated
  scale, not a general recommendation.
- *Writes are not concurrent.* Only the ingestion task writes, and it writes a new prefix rather
  than mutating an existing one, so this is a constraint rather than a problem.
- *Every task holds a full copy.* Fine at this corpus size; a scaling limit at 100x.
- *Index freshness is bounded by task restart.* A promoted index reaches a running task only when
  that task restarts. The promotion pipeline forces a rolling restart, which makes this explicit
  rather than eventual.

**Superseded when:** the corpus exceeds ~1M chunks, or sub-minute index freshness becomes a
requirement. The migration target is OpenSearch Serverless behind the same `Retriever` protocol —
`retrieval.py` defines the seam, so the blast radius is one module and one Terraform variable.
