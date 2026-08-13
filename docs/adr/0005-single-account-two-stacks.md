# ADR-0005 — One AWS account with two isolated stacks, not two accounts

**Status:** accepted · **Date:** 2026-08 · **Decides:** the environment boundary

## Context

The strongest environment isolation on AWS is the account boundary: separate credentials, separate
quotas, separate bills, and no IAM policy mistake that can reach across. That is the correct target
state and what a production Pfizer platform should use.

This case study runs in a single personal AWS account. AWS Organizations with separate nonprod and
prod accounts is available, but it adds an Organizations setup, cross-account role chaining and a
second state bucket to a piece of work whose subject is the *pipeline*, not the landing zone.

## Decision

Run nonprod and prod as fully separate Terraform stacks in one account, with the account boundary
deliberately isolated to a small number of variables so that splitting later is a configuration
change rather than a rewrite.

**What is genuinely separate per environment:** VPC and subnets, ALB and target groups, ECS cluster
and service, task role and execution role, index bucket, SSM parameter namespace, log groups,
CloudWatch alarms, Terraform state key.

**What is deliberately shared:** the ECR repositories — because promoting *the same digest* from
dev to prod is the entire point, and copying images between accounts weakens that guarantee — and
the GitHub OIDC provider.

**What compensates for the missing account boundary:**

- Three separate pipeline roles (`cipipeline`, `releasepipeline`, `deploymentpipeline`) with
  disjoint permissions. CI can read; release can push to ECR; only deployment can touch
  environments.
- The deployment role's trust policy is scoped to the GitHub *environment* claim, so prod
  credentials are only issuable from a job running in the `prod` GitHub environment — which has a
  required reviewer. The approval gate sits in front of the credentials, not merely in front of the
  apply.
- Resource-level IAM: each task role can read only its own environment's index bucket prefix and
  only its own SSM namespace.

## Consequences

- A misconfigured IAM policy could in principle reach across environments. Two accounts make that
  structurally impossible; this design makes it require a specific mistake in a reviewed file.
- No per-environment service quotas or billing separation. Cost is tracked by tag instead.
- Migrating to two accounts changes the provider block, the state bucket and the role ARNs. The
  modules and the workflows do not change — the environment compositions already parameterise
  everything that would differ.

**Superseded when:** the work runs anywhere real. This is a scope decision, not an architectural
preference.
