#!/usr/bin/env bash
# Waits for one ECS deployment and reports what actually happened to it.
#
#   bash scripts/wait_for_deployment.sh <cluster> <service> <previous-deployment-arn> [base-url]
#
# Shared because deploy.sh and promote_index.sh both start a deployment and both need the same
# answer. `aws ecs wait services-stable` cannot give it, for two reasons: its budget is a fixed
# 10 minutes, which is shorter than a canary release, and a deployment the alarms reversed reaches
# a steady state exactly like one that succeeded.
set -euo pipefail

CLUSTER="${1:-}"
SERVICE="${2:-}"
PREVIOUS="${3:-none}"
BASE_URL="${4:-}"
TIMEOUT="${DEPLOY_TIMEOUT_SECONDS:-3600}"

die() { printf 'wait: %s\n' "$*" >&2; exit 1; }

[ -n "$CLUSTER" ] || die "usage: wait_for_deployment.sh <cluster> <service> [previous-arn] [base-url]"
[ -n "$SERVICE" ] || die "usage: wait_for_deployment.sh <cluster> <service> [previous-arn] [base-url]"

deadline=$(( $(date +%s) + TIMEOUT ))
started=$(date +%s)

while :; do
  read -r deployment status <<EOF
$(aws ecs list-service-deployments --cluster "$CLUSTER" --service "$SERVICE" \
  --query 'serviceDeployments[0].[serviceDeploymentArn,status]' --output text 2>/dev/null || echo "none UNKNOWN")
EOF

  # Until ECS registers ours, the most recent deployment is still the one that preceded it — and
  # that one reports SUCCESSFUL, which would end this wait before the release had even started.
  if [ "$deployment" = "$PREVIOUS" ] || [ -z "$deployment" ]; then
    status="REGISTERING"
  fi

  case "$status" in
    SUCCESSFUL)
      printf 'wait: deployment succeeded after %ds\n' "$(( $(date +%s) - started ))"
      exit 0
      ;;
    ROLLBACK_SUCCESSFUL | ROLLBACK_IN_PROGRESS)
      die "ECS is reversing this deployment ($status) — the previous version is what is serving"
      ;;
    ROLLBACK_FAILED | STOPPED | STOP_REQUESTED)
      die "deployment ended as $status"
      ;;
  esac

  # A canary is minutes of deliberate waiting, and a step that prints nothing for half an hour is
  # indistinguishable from one that has hung — an operator who believes a release is stuck is an
  # operator about to make it worse.
  #
  # The probe is also load-bearing: on a service with no real users the alarms see no datapoints,
  # so a canary carrying 10% of nothing cannot fail. One request per poll is a floor, not a
  # substitute for real traffic — see docs/decisions.md.
  probe=""
  if [ -n "$BASE_URL" ]; then
    probe=" probe=$(curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' "${BASE_URL%/}/healthz" 2>/dev/null || echo ---)"
  fi
  printf 'wait: [%4ds] %-12s%s\n' "$(( $(date +%s) - started ))" "$status" "$probe"

  [ "$(date +%s)" -lt "$deadline" ] || die "deployment still $status after ${TIMEOUT}s"
  sleep 15
done
