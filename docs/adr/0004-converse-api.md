# ADR-0004 — Bedrock through the Converse API, with the model id as a variable

**Status:** accepted · **Date:** 2026-08 · **Decides:** how the service calls a foundation model

## Context

Bedrock exposes two invocation paths: `invoke_model`, which takes a provider-specific JSON body,
and `converse`, which normalises messages, system prompts, inference parameters and token usage
across providers.

`invoke_model` gives access to every provider-specific parameter. `converse` gives portability at
the cost of the long tail of those parameters.

## Decision

Use `converse`, and make the model id a Terraform variable propagated to the task as
`RAG_TEXT_MODEL_ID`. The IAM policy derives the permitted foundation-model ARNs from that same
variable rather than granting `bedrock:InvokeModel` on `*`.

## Consequences

**This decision paid for itself during the build.** The intended model was
`us.anthropic.claude-haiku-4-5-20251001-v1:0`. Every invocation failed with
`ResourceNotFoundException` and the message *"Model use case details have not been submitted for
this account. Fill out the Anthropic use case details form before using the model."* — an
out-of-band console approval that cannot be expressed in Terraform and would have to be repeated by
anyone reproducing this repo.

Switching to `us.amazon.nova-lite-v1:0` was a change to one variable default. No application code
changed, no request-building code changed, and the IAM policy re-derived the correct ARNs on the
next apply. Under `invoke_model` this would have been a rewrite of the request body, the response
parser and the token-usage extraction.

**Other consequences.**

- *Model ids must be inference profile ids, not bare foundation-model ids.* Current-generation
  models are only invokable through a cross-region profile. Invoking one requires IAM permission on
  the profile ARN *and* on the underlying foundation-model ARN in every region the profile may
  route to, so the policy computes the base id by stripping the `us.` / `eu.` / `global.` prefix
  and grants the three US regions. Granting `bedrock:*` on `*` would have been one line and is the
  reason this is written down.
- *Some provider parameters are unavailable.* Acceptable: this service uses `temperature` and
  `maxTokens` and nothing else.
- *Sampling parameters are not uniformly accepted.* Anthropic models reject `temperature` and
  `topP` in the same request with a `ValidationException`. The service sends `temperature: 0.0`
  alone — deterministic output also keeps the eval gate a measurement rather than a coin flip.
- *Cost is observable per request.* `converse` returns `usage.inputTokens` / `outputTokens`
  uniformly, which is what makes per-request token cost a logged field rather than a monthly
  surprise.

**Switching back to Claude** requires only that the account's Anthropic use case form be approved,
then `-var text_model_id=us.anthropic.claude-haiku-4-5-20251001-v1:0`.
