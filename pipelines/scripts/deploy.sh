#!/usr/bin/env bash
# Deploys one release to one environment.
#
#   ENV=nonprod/dev VERSION=v0.1.0 bash pipelines/scripts/deploy.sh
#
# The same script runs locally and in CI. Nothing in the deployment path is reachable only from a
# workflow, which is what makes an incident at 2am survivable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKEND_FILE="$REPO_ROOT/infra/backend.hcl"

ENV_PATH="${ENV:-}"
VERSION="${VERSION:-}"
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-rag}"

die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

[ -n "$ENV_PATH" ] || die "ENV is required, e.g. ENV=nonprod/dev"
[ -n "$VERSION" ] || die "VERSION is required, e.g. VERSION=v0.1.0"
[ -f "$BACKEND_FILE" ] || die "infra/backend.hcl missing — run bootstrap.sh first"

ENV_DIR="$REPO_ROOT/infra/envs/$ENV_PATH"
[ -d "$ENV_DIR" ] || die "no environment at infra/envs/$ENV_PATH"

account_id="$(aws sts get-caller-identity --query Account --output text)" || die "no AWS credentials"
registry="${account_id}.dkr.ecr.${REGION}.amazonaws.com"

# Resolve the tag to a digest and deploy that. A tag records what someone intended; a digest
# records which bytes ran. Promoting by digest is what makes "dev and prod are identical" a fact
# rather than a hope.
digest="$(aws ecr describe-images \
  --repository-name "${PROJECT}-api" \
  --image-ids "imageTag=${VERSION}" \
  --query 'imageDetails[0].imageDigest' \
  --output text 2>/dev/null)" || die "release $VERSION not found in ECR — run release.yml first"

[ -n "$digest" ] && [ "$digest" != "None" ] || die "could not resolve a digest for $VERSION"

image="${registry}/${PROJECT}-api@${digest}"
git_sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

printf 'deploy: %s -> %s\n  image  %s\n' "$VERSION" "$ENV_PATH" "$image"

terraform -chdir="$ENV_DIR" init -input=false -reconfigure -backend-config="$BACKEND_FILE"
terraform -chdir="$ENV_DIR" apply -input=false -auto-approve \
  -var "image=$image" \
  -var "release_version=$VERSION" \
  -var "git_sha=$git_sha"

controller="$(terraform -chdir="$ENV_DIR" output -raw deployment_controller)"
api_url="$(terraform -chdir="$ENV_DIR" output -raw api_url)"

if [ "$controller" = "ECS" ]; then
  # Terraform has already registered the new task definition; the circuit breaker handles a task
  # set that never becomes healthy by restoring the previous one, with no pipeline step involved.
  cluster="$(terraform -chdir="$ENV_DIR" output -raw cluster_name)"
  service="$(terraform -chdir="$ENV_DIR" output -raw service_name)"
  family="$(terraform -chdir="$ENV_DIR" output -raw task_definition_family)"

  printf 'deploy: rolling update with circuit breaker\n'
  aws ecs update-service \
    --cluster "$cluster" \
    --service "$service" \
    --task-definition "$family" \
    --no-cli-pager >/dev/null

  aws ecs wait services-stable --cluster "$cluster" --services "$service" \
    || die "service did not stabilise — the circuit breaker should have rolled it back; check the events"
else
  printf 'deploy: blue/green via CodeDeploy — canary, then alarm-gated shift\n'
  bash "$REPO_ROOT/pipelines/scripts/codedeploy_release.sh" "$ENV_DIR" "$image"
fi

bash "$REPO_ROOT/pipelines/scripts/smoke.sh" "$api_url" "$VERSION"

printf 'deploy: %s is serving %s at %s\n' "$ENV_PATH" "$VERSION" "$api_url"
