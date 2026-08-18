#!/usr/bin/env bash
# Drives one CodeDeploy blue/green release and waits for the traffic shift to finish.
#
#   bash scripts/codedeploy_release.sh <env-dir> <image>
#
# Split out of deploy.sh because the blue/green path is where a release actually gets interesting:
# it can succeed, fail, or be reversed by an alarm while it is still running, and each of those
# needs a different exit code and a different message.
set -euo pipefail

ENV_DIR="${1:-}"
IMAGE="${2:-}"

die() { printf 'codedeploy: %s\n' "$*" >&2; exit 1; }

[ -n "$ENV_DIR" ] && [ -n "$IMAGE" ] || die "usage: codedeploy_release.sh <env-dir> <image>"

app="$(terraform -chdir="$ENV_DIR" output -raw codedeploy_application_name)"
group="$(terraform -chdir="$ENV_DIR" output -raw codedeploy_deployment_group_name)"
family="$(terraform -chdir="$ENV_DIR" output -raw task_definition_family)"

[ -n "$app" ] && [ "$app" != "null" ] || die "environment has no CodeDeploy application"

# Terraform already registered a revision containing the new image; CodeDeploy needs to be told
# which one to shift to.
task_def_arn="$(aws ecs describe-task-definition \
  --task-definition "$family" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"

printf 'codedeploy: shifting to %s\n' "$task_def_arn"

appspec="$(cat <<EOF
{
  "version": 1,
  "Resources": [
    {
      "TargetService": {
        "Type": "AWS::ECS::Service",
        "Properties": {
          "TaskDefinition": "${task_def_arn}",
          "LoadBalancerInfo": { "ContainerName": "api", "ContainerPort": 8080 }
        }
      }
    }
  ]
}
EOF
)"

deployment_id="$(aws deploy create-deployment \
  --application-name "$app" \
  --deployment-group-name "$group" \
  --revision "revisionType=AppSpecContent,appSpecContent={content='$(printf '%s' "$appspec" | tr -d '\n')'}" \
  --query 'deploymentId' --output text)"

printf 'codedeploy: deployment %s started\n' "$deployment_id"

# The wait is the point: this is where the canary runs and where an alarm can reverse it.
if aws deploy wait deployment-successful --deployment-id "$deployment_id"; then
  printf 'codedeploy: %s succeeded — traffic fully shifted\n' "$deployment_id"
  exit 0
fi

status="$(aws deploy get-deployment --deployment-id "$deployment_id" \
  --query 'deploymentInfo.status' --output text 2>/dev/null || echo UNKNOWN)"
reason="$(aws deploy get-deployment --deployment-id "$deployment_id" \
  --query 'deploymentInfo.rollbackInfo.rollbackMessage' --output text 2>/dev/null || echo '')"

printf 'codedeploy: deployment %s ended as %s\n' "$deployment_id" "$status"
[ -n "$reason" ] && [ "$reason" != "None" ] && printf 'codedeploy: %s\n' "$reason"

# A rollback is the safety mechanism working, not a pipeline bug — but the job must still fail so
# the release is not recorded as promoted.
die "blue/green release did not complete; previous task set remains live"
