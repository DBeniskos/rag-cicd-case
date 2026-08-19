#!/usr/bin/env bash
# Creates the GitHub OIDC provider, the three pipeline roles and the ECR repositories.
# Run once, after bootstrap.sh, with admin credentials. Everything after this uses OIDC.
#
#   GITHUB_REPOSITORY=owner/repo bash scripts/platform.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_DIR="$REPO_ROOT/infra/platform"
BACKEND_FILE="$REPO_ROOT/infra/backend.hcl"

PROJECT="${PROJECT:-rag}"
REGION="${AWS_REGION:-us-east-1}"
ASSUME_YES="${ASSUME_YES:-false}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v terraform >/dev/null 2>&1 || die "terraform not found"
[ -f "$BACKEND_FILE" ] || die "infra/backend.hcl missing — run scripts/bootstrap.sh first"

account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "no usable AWS credentials. Run 'aws configure' or export AWS_PROFILE."

GH_REPO="${GITHUB_REPOSITORY:-}"
if [ -z "$GH_REPO" ]; then
  [ -t 0 ] || die "no terminal attached — set GITHUB_REPOSITORY=owner/repo and re-run"
  read -r -p "GitHub repository allowed to deploy (owner/repo): " GH_REPO
fi
# A malformed value here silently widens who can assume a deploy role, so it is checked twice:
# here for a fast failure, and again in the Terraform variable validation.
printf '%s' "$GH_REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
  || die "GITHUB_REPOSITORY must be exactly owner/repo, got '$GH_REPO'"

# GitHub's OIDC subject claim embeds numeric owner and repository ids. Looking them up here keeps
# the trust policy pinned to the identity rather than the name, and spares anyone reusing this
# repo from finding the ids by hand.
OWNER_ID="${GITHUB_OWNER_ID:-}"
REPO_ID="${GITHUB_REPOSITORY_ID:-}"
if [ -z "$OWNER_ID" ] || [ -z "$REPO_ID" ]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    OWNER_ID="$(gh api "users/${GH_REPO%%/*}" --jq .id 2>/dev/null || true)"
    REPO_ID="$(gh api "repos/${GH_REPO}" --jq .id 2>/dev/null || true)"
  fi
fi
if [ -z "$OWNER_ID" ] || [ -z "$REPO_ID" ]; then
  printf 'warning: could not resolve GitHub numeric ids; falling back to name-based claims.\n' >&2
  printf '         If OIDC fails with AccessDenied, set GITHUB_OWNER_ID and GITHUB_REPOSITORY_ID.\n' >&2
fi

cat <<EOF

Platform — GitHub OIDC provider, pipeline roles, ECR.

  account    : $account_id
  region     : $REGION
  repository : $GH_REPO   (only this repo may assume the roles)
  subject    : ${OWNER_ID:+immutable ids ${OWNER_ID}/${REPO_ID}}${OWNER_ID:-name-based claim}

EOF

if [ "$ASSUME_YES" != "true" ]; then
  [ -t 0 ] || die "no terminal attached — set ASSUME_YES=true, or run interactively"
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    y | Y) ;;
    *) die "aborted" ;;
  esac
fi

terraform -chdir="$PLATFORM_DIR" init -input=false -backend-config="$BACKEND_FILE"
terraform -chdir="$PLATFORM_DIR" apply -input=false -auto-approve \
  -var "project=$PROJECT" \
  -var "region=$REGION" \
  -var "github_repository=$GH_REPO" \
  -var "github_owner_id=$OWNER_ID" \
  -var "github_repository_id=$REPO_ID"

ci_role="$(terraform -chdir="$PLATFORM_DIR" output -raw ci_role_arn)"
release_role="$(terraform -chdir="$PLATFORM_DIR" output -raw release_role_arn)"
deploy_role="$(terraform -chdir="$PLATFORM_DIR" output -raw deployment_role_arn)"
registry="$(terraform -chdir="$PLATFORM_DIR" output -raw ecr_registry)"
# CI cannot read infra/backend.hcl (gitignored), so it rebuilds the backend config from variables.
state_bucket="$(grep -E '^bucket' "$BACKEND_FILE" | cut -d'"' -f2)"

cat <<EOF

Done. Set these as GitHub repository *variables* (Settings -> Secrets and variables -> Actions
-> Variables). They are identifiers, not secrets — but they name your account, so they belong in
repository settings rather than in committed YAML.

  AWS_REGION            $REGION
  AWS_CI_ROLE_ARN       $ci_role
  AWS_RELEASE_ROLE_ARN  $release_role
  AWS_DEPLOY_ROLE_ARN   $deploy_role
  ECR_REGISTRY          $registry
  TF_STATE_BUCKET       $state_bucket

With the GitHub CLI:

  gh variable set AWS_REGION           --body "$REGION"
  gh variable set AWS_CI_ROLE_ARN      --body "$ci_role"
  gh variable set AWS_RELEASE_ROLE_ARN --body "$release_role"
  gh variable set AWS_DEPLOY_ROLE_ARN  --body "$deploy_role"
  gh variable set ECR_REGISTRY         --body "$registry"
  gh variable set TF_STATE_BUCKET      --body "$state_bucket"

Optionally, an address to receive alarm notifications. Without it the alarm topics exist and are
published to, but have no subscriber, so a rollback is never announced to anyone. A *secret*, not
a variable: an address is personal data and Actions logs on a public repo are world-readable.

  gh secret set ALERT_EMAIL            --body "you@example.com"

AWS emails a confirmation link on the next deploy; the subscription delivers nothing until it is
clicked, and AWS discards it entirely if it is left unconfirmed for three days.

Also create the GitHub environments 'dev' and 'prod' (Settings -> Environments). The deploy role
trusts the environment claim, so deploys fail closed until they exist — and 'prod' is where the
manual approval gate is configured.
EOF
