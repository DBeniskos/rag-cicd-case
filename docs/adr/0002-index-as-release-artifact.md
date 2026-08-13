# ADR-0002 — The index is a first-class release artefact with its own pipeline

**Status:** accepted · **Date:** 2026-08 · **Decides:** how index changes reach production

## Context

In a RAG service the deployable surface is larger than the container image. Answer quality can
regress with no application change at all — a re-chunked corpus, a new embedding model, a document
added or withdrawn. Treating the index as configuration or as data baked into the image collapses
two independent failure domains into one.

Two anti-patterns were rejected outright:

1. **Index baked into the image.** Makes every corpus change a full build, test and deploy cycle,
   and makes rolling back a bad corpus require rolling back the service too.
2. **Index rebuilt in place at deploy time.** Destroys the previous index, so there is nothing to
   roll back to, and makes the deploy's duration depend on corpus size.

## Decision

The index has its own version scheme, its own pipeline, and its own promotion and rollback path.

- **Version identity.** `v<n>-<corpus-hash>` — a monotonic build number plus the first seven
  characters of a hash over the corpus contents. The hash means an identical corpus is recognisable
  as such; the counter means ordering is obvious to a human at 2am.
- **Immutability.** A version is written once and never modified. `manifest.json` is uploaded
  *last*, so a partially uploaded index has no manifest and is therefore never loadable — the
  upload is effectively atomic from the reader's point of view.
- **Promotion.** `index.yml` writes `/rag/<env>/active_index_version` and forces a rolling restart.
- **Compatibility.** The API refuses to serve an index whose manifest declares a different
  embedding model or dimension count than the API is configured to use
  (`EmbeddingModelMismatchError` → 503). A dimension mismatch would otherwise produce confidently
  wrong retrieval rather than an error, which is far worse.

## Consequences

- Two rollback stories, both exercised: `deploy.yml` at the previous version for the service,
  `index.yml --rollback` for the index. The runbook treats them as separate incidents because they
  have separate causes.
- The eval gate runs on both pipelines. An index promotion is gated on answer quality exactly as a
  service deploy is.
- Old index versions accumulate in S3. A lifecycle rule expires non-current versions after 90 days;
  the retention window is deliberately longer than any plausible "we need to go back" conversation.
- The ingestion job needs its own IAM role — it is the only principal that may write to the index
  prefix, and the API role is read-only. A compromised API task cannot poison the index.
