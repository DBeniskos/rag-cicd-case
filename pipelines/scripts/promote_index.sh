#!/usr/bin/env bash
# Promotes or rolls back the index an environment serves.
#
#   ENV=nonprod/dev bash pipelines/scripts/promote_index.sh v3-abc1234   # promote
#   ENV=nonprod/dev bash pipelines/scripts/promote_index.sh --rollback   # previous version
#   ENV=nonprod/dev bash pipelines/scripts/promote_index.sh --status
#
# Promotion is a pointer flip, not a copy. Index versions are immutable, so going back is the same
# operation as going forward — seconds, no rebuild, no Bedrock spend. That is the whole reason the
# index is versioned rather than overwritten in place.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ENV_PATH="${ENV:-}"
TARGET="${1:-}"
PROJECT="${PROJECT:-rag}"
REGION="${AWS_REGION:-us-east-1}"

die() { printf 'promote: %s\n' "$*" >&2; exit 1; }

[ -n "$ENV_PATH" ] || die "ENV is required, e.g. ENV=nonprod/dev"
[ -n "$TARGET" ] || die "usage: promote_index.sh <index-version|--rollback|--status>"

# The environment name is the last path segment: nonprod/dev -> dev.
ENV_NAME="${ENV_PATH##*/}"
PARAM="/${PROJECT}/${ENV_NAME}/active_index_version"
ENV_DIR="$REPO_ROOT/infra/envs/$ENV_PATH"

current="$(aws ssm get-parameter --name "$PARAM" --query 'Parameter.Value' --output text 2>/dev/null)" \
  || die "$PARAM not found — has $ENV_PATH been deployed?"

if [ "$TARGET" = "--status" ]; then
  printf 'active index in %s: %s\n' "$ENV_NAME" "$current"
  # Parameter history is the audit trail: who promoted what, and when.
  aws ssm get-parameter-history --name "$PARAM" --max-items 5 \
    --query 'reverse(Parameters[].{version:Version,value:Value,at:LastModifiedDate})' \
    --output table 2>/dev/null || true
  exit 0
fi

if [ "$TARGET" = "--rollback" ]; then
  # The previous value is read from parameter history rather than tracked separately, so rollback
  # works even from a machine that has never promoted anything.
  previous="$(aws ssm get-parameter-history --name "$PARAM" \
    --query 'reverse(Parameters[].Value)' --output text 2>/dev/null | tr '\t' '\n' \
    | grep -v "^${current}$" | head -n1)"

  [ -n "$previous" ] || die "no earlier version in history — nothing to roll back to"
  TARGET="$previous"
  printf 'promote: rolling back %s -> %s\n' "$current" "$TARGET"
fi

[ "$TARGET" != "$current" ] || { printf 'promote: %s already active\n' "$TARGET"; exit 0; }

# Pointing at an index that does not exist would fail the next task start, and the failure would
# surface as a crash loop rather than as "you promoted a typo". Checking first is cheaper.
if [ "$TARGET" != "none" ]; then
  bucket="$(terraform -chdir="$ENV_DIR" output -raw index_bucket 2>/dev/null)" \
    || die "cannot read index_bucket output — run terraform init in $ENV_DIR"
  aws s3api head-object --bucket "$bucket" --key "indexes/${TARGET}/manifest.json" >/dev/null 2>&1 \
    || die "no manifest at s3://${bucket}/indexes/${TARGET}/ — refusing to promote a missing index"
fi

aws ssm put-parameter --name "$PARAM" --value "$TARGET" --type String --overwrite >/dev/null
printf 'promote: %s now points at %s\n' "$ENV_NAME" "$TARGET"

# The pointer is read at task startup, so running tasks keep serving the old index until they are
# replaced. Forcing a new deployment is what makes the flip take effect.
cluster="$(terraform -chdir="$ENV_DIR" output -raw cluster_name 2>/dev/null || echo '')"
service="$(terraform -chdir="$ENV_DIR" output -raw service_name 2>/dev/null || echo '')"

if [ -n "$cluster" ] && [ -n "$service" ]; then
  printf 'promote: restarting %s to pick up the new pointer\n' "$service"
  aws ecs update-service --cluster "$cluster" --service "$service" \
    --force-new-deployment --no-cli-pager >/dev/null
  aws ecs wait services-stable --cluster "$cluster" --services "$service" \
    || die "service did not stabilise on $TARGET — roll back with --rollback"
  printf 'promote: %s is serving index %s\n' "$service" "$TARGET"
else
  printf 'promote: no service outputs found; pointer set but nothing restarted\n'
fi
