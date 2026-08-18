#!/usr/bin/env bash
# Deploys one release to one environment.
#
#   ENV=dev VERSION=v0.1.0 bash scripts/deploy.sh
#
# The same script runs locally and in CI. Nothing in the deployment path is reachable only from a
# workflow, which is what makes an incident at 2am survivable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_FILE="$REPO_ROOT/infra/backend.hcl"

ENV_PATH="${ENV:-}"
VERSION="${VERSION:-}"
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-rag}"

die() { printf 'deploy: %s\n' "$*" >&2; exit 1; }

[ -n "$ENV_PATH" ] || die "ENV is required, e.g. ENV=dev"
[ -n "$VERSION" ] || die "VERSION is required, e.g. VERSION=v0.1.0"
[ -f "$BACKEND_FILE" ] || die "infra/backend.hcl missing — run bootstrap.sh first"

ENV_DIR="$REPO_ROOT/infra/envs/$ENV_PATH"
[ -d "$ENV_DIR" ] || die "no environment at infra/envs/$ENV_PATH"

account_id="$(aws sts get-caller-identity --query Account --output text)" || die "no AWS credentials"
registry="${account_id}.dkr.ecr.${REGION}.amazonaws.com"

# Resolve each tag to a digest and deploy that. A tag records what someone intended; a digest
# records which bytes ran. Promoting by digest is what makes "dev and prod are identical" a fact
# rather than a hope. Both components are resolved from the same version so the API and the job
# that builds its index are always from one commit.
resolve_digest() {
  local repo="$1" digest
  digest="$(aws ecr describe-images \
    --repository-name "$repo" \
    --image-ids "imageTag=${VERSION}" \
    --query 'imageDetails[0].imageDigest' \
    --output text 2>/dev/null)" || die "release $VERSION not found in $repo — run release.yml first"
  [ -n "$digest" ] && [ "$digest" != "None" ] || die "could not resolve a digest for $repo:$VERSION"
  printf '%s' "$digest"
}

api_image="${registry}/${PROJECT}-api@$(resolve_digest "${PROJECT}-api")"
ingest_image="${registry}/${PROJECT}-ingest@$(resolve_digest "${PROJECT}-ingest")"
git_sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

printf 'deploy: %s -> %s\n  api    %s\n  ingest %s\n' "$VERSION" "$ENV_PATH" "$api_image" "$ingest_image"

terraform -chdir="$ENV_DIR" init -input=false -reconfigure -backend-config="$BACKEND_FILE"

# Read before the apply, because "the most recent deployment" one second after an apply is still
# the previous one — and it reports SUCCESSFUL, which would make the wait below exit immediately
# and smoke-test the release we just replaced. Empty on a first deploy, which is also correct.
previous_deployment="$(aws ecs list-service-deployments \
  --cluster "$(terraform -chdir="$ENV_DIR" output -raw cluster_name 2>/dev/null || echo missing)" \
  --service "$(terraform -chdir="$ENV_DIR" output -raw service_name 2>/dev/null || echo missing)" \
  --query 'serviceDeployments[0].serviceDeploymentArn' --output text 2>/dev/null || echo none)"

terraform -chdir="$ENV_DIR" apply -input=false -auto-approve \
  -var "image=$api_image" \
  -var "ingest_image=$ingest_image" \
  -var "release_version=$VERSION" \
  -var "git_sha=$git_sha"

strategy="$(terraform -chdir="$ENV_DIR" output -raw deployment_strategy)"
api_url="$(terraform -chdir="$ENV_DIR" output -raw api_url)"
cluster="$(terraform -chdir="$ENV_DIR" output -raw cluster_name)"
service="$(terraform -chdir="$ENV_DIR" output -raw service_name)"
# Null wherever the strategy is rolling, which is why the failure is swallowed rather than fatal.
test_url="$(terraform -chdir="$ENV_DIR" output -raw test_url 2>/dev/null || echo '')"

# Both strategies are driven by ECS itself, so the apply above already started the release. The
# difference is what ECS does with it: a rolling replacement guarded by the circuit breaker, or a
# staged shift onto a second task set that alarms can reverse.
if [ "$strategy" = "ROLLING" ]; then
  printf 'deploy: rolling update with circuit breaker\n'
else
  printf 'deploy: %s — shift onto a second task set, bake, then retire the old one\n' "$strategy"
fi

bash "$REPO_ROOT/scripts/wait_for_deployment.sh" \
  "$cluster" "$service" "$previous_deployment" "$api_url" "$test_url"

bash "$REPO_ROOT/scripts/smoke.sh" "$api_url" "$VERSION"

printf 'deploy: %s is serving %s at %s\n' "$ENV_PATH" "$VERSION" "$api_url"
