#!/usr/bin/env bash
# Waits for one ECS deployment, and leaves behind evidence of what it did.
#
#   bash scripts/wait_for_deployment.sh <cluster> <service> <previous-arn> [base-url] [test-url]
#
# Shared because deploy.sh and promote_index.sh both start a deployment and both need the same
# answer. `aws ecs wait services-stable` cannot give it, for two reasons: its budget is a fixed
# 10 minutes, which is shorter than a canary release, and a deployment the alarms reversed reaches
# a steady state exactly like one that succeeded.
#
# The output is deliberately verbose. A canary is minutes of silence otherwise, and "the release
# looked hung so I cancelled it" is a real incident. Every traffic shift is printed when it
# happens and repeated as a table in the job summary, so the log is the audit trail.
set -euo pipefail

CLUSTER="${1:-}"
SERVICE="${2:-}"
PREVIOUS="${3:-none}"
BASE_URL="${4:-}"
TEST_URL="${5:-}"
TIMEOUT="${DEPLOY_TIMEOUT_SECONDS:-3600}"
# Enough requests per poll that a 60-second alarm period has a population to work with. A canary
# carrying 10% of nothing produces no datapoints, and alarms that cannot fire are decoration.
LOAD="${CANARY_LOAD_REQUESTS:-25}"

die() { printf 'wait: %s\n' "$*" >&2; exit 1; }

[ -n "$CLUSTER" ] || die "usage: wait_for_deployment.sh <cluster> <service> [previous-arn] [base-url] [test-url]"
[ -n "$SERVICE" ] || die "usage: wait_for_deployment.sh <cluster> <service> [previous-arn] [base-url] [test-url]"

BASE_URL="${BASE_URL%/}"
TEST_URL="${TEST_URL%/}"
TIMELINE="$(mktemp)"

# Reproduced into the job summary so the traffic shifts survive after the log scrolls away.
emit_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  [ -s "$TIMELINE" ] || return 0
  {
    printf '\n#### Traffic timeline\n\n'
    if [ -n "$TEST_URL" ]; then
      printf '| elapsed | event | live (:80) | test listener (:8080) |\n| --- | --- | --- | --- |\n'
    else
      printf '| elapsed | event | live |\n| --- | --- | --- |\n'
    fi
    cat "$TIMELINE"
    printf '\n'
  } >> "$GITHUB_STEP_SUMMARY"
}
trap emit_summary EXIT

# Resolved once: the listener rule is what ECS rewrites to move traffic, so its weights are the
# only honest answer to "how much of production is on the new version right now". taskSets is not
# usable here — ECS reports it as null for the CANARY strategy even mid-deployment.
resolve_alb() {
  local tg_arn lb_arn
  tg_arn="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].loadBalancers[0].targetGroupArn' --output text 2>/dev/null || echo None)"
  [ "$tg_arn" != "None" ] && [ -n "$tg_arn" ] || return 1

  lb_arn="$(aws elbv2 describe-target-groups --target-group-arns "$tg_arn" \
    --query 'TargetGroups[0].LoadBalancerArns[0]' --output text 2>/dev/null || echo None)"
  [ "$lb_arn" != "None" ] && [ -n "$lb_arn" ] || return 1

  TG_NAMES="$(aws elbv2 describe-target-groups --load-balancer-arn "$lb_arn" \
    --query 'TargetGroups[].[TargetGroupArn,TargetGroupName]' --output text 2>/dev/null || true)"
  PROD_LISTENER="$(aws elbv2 describe-listeners --load-balancer-arn "$lb_arn" \
    --query 'Listeners[?Port==`80`].ListenerArn' --output text 2>/dev/null || true)"
  [ -n "$PROD_LISTENER" ]
}

# "blue=90% green=10%" — percentages rather than raw weights, because ELB expresses 90/10 as
# 900/100 and nobody reading an incident log should have to do that division themselves.
weights() {
  [ -n "${PROD_LISTENER:-}" ] || { printf 'unknown'; return; }
  aws elbv2 describe-rules --listener-arn "$PROD_LISTENER" \
    --query "Rules[?Priority=='1'].Actions[0].ForwardConfig.TargetGroups[].[TargetGroupArn,Weight]" \
    --output text 2>/dev/null | awk -v names="$TG_NAMES" '
      BEGIN { n = split(names, rows, "\n"); for (i = 1; i <= n; i++) { split(rows[i], kv, "\t"); name[kv[1]] = kv[2] } }
      { arn[NR] = $1; w[NR] = $2; total += $2 }
      END {
        if (NR == 0) { printf "unknown"; exit }
        for (i = 1; i <= NR; i++) {
          short = name[arn[i]]; sub(/^.*-/, "", short)
          printf "%s%s=%d%%", (i > 1 ? " " : ""), short, (total > 0 ? w[i] * 100 / total : 0)
        }
      }'
}

release_at() {
  local url="$1"
  [ -n "$url" ] || { printf -- '-'; return; }
  curl -fsS --max-time 5 "$url/healthz" 2>/dev/null \
    | sed -n 's/.*"release"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n1 | grep . || printf -- '-'
}

# Load exists so the alarms have a population to evaluate. /healthz costs nothing and touches
# neither retrieval nor Bedrock, which also means a release that breaks /ask while /healthz stays
# green will not be caught here — see docs/decisions.md.
generate_load() {
  [ -n "$BASE_URL" ] || return 0
  local i
  for i in $(seq 1 "$LOAD"); do
    curl -fsS --max-time 5 -o /dev/null "$BASE_URL/healthz" 2>/dev/null || true &
  done
  wait
}

resolve_alb || printf 'wait: could not resolve the load balancer; traffic weights will not be reported\n'

deadline=$(( $(date +%s) + TIMEOUT ))
started=$(date +%s)
last_weights=""

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

  elapsed=$(( $(date +%s) - started ))
  now="$(weights)"
  live="$(release_at "$BASE_URL")"

  # Only meaningful where a second task set exists; a rolling update has no test listener, and
  # printing an always-empty column makes it look like it does.
  canary_col=""
  canary_cell=""
  if [ -n "$TEST_URL" ]; then
    canary_col="  test=$(release_at "$TEST_URL")"
    canary_cell=" \`$(release_at "$TEST_URL")\` |"
  fi

  # Only transitions are worth reporting; the polls between them are noise. The first reading is
  # the state we started from rather than a shift — calling it one makes a rolling update, which
  # never moves traffic between target groups at all, look like it has canary machinery.
  if [ "$now" != "$last_weights" ]; then
    if [ -z "$last_weights" ]; then
      event="baseline"
    else
      event="TRAFFIC SHIFT"
    fi
    printf 'wait: >>> [%4ds] %-13s %s   live=%s%s\n' "$elapsed" "$event" "$now" "$live" "$canary_col"
    printf '| %ds | %s → %s | `%s` |%s\n' "$elapsed" "$event" "$now" "$live" "$canary_cell" >> "$TIMELINE"
    last_weights="$now"
  fi

  case "$status" in
    SUCCESSFUL)
      printf 'wait: [%4ds] SUCCEEDED     %s   live=%s\n' "$elapsed" "$now" "$live"
      printf '| %ds | **deployment succeeded** | `%s` |%s\n' "$elapsed" "$live" "$canary_cell" >> "$TIMELINE"
      exit 0
      ;;
    ROLLBACK_SUCCESSFUL | ROLLBACK_IN_PROGRESS)
      printf 'wait: [%4ds] ROLLING BACK  %s   live=%s\n' "$elapsed" "$now" "$live"
      printf '| %ds | **ROLLED BACK** (%s) | `%s` |%s\n' "$elapsed" "$status" "$live" "$canary_cell" >> "$TIMELINE"
      die "ECS is reversing this deployment ($status) — the previous version is what is serving"
      ;;
    ROLLBACK_FAILED | STOPPED | STOP_REQUESTED)
      printf '| %ds | **%s** | `%s` |%s\n' "$elapsed" "$status" "$live" "$canary_cell" >> "$TIMELINE"
      die "deployment ended as $status"
      ;;
  esac

  printf 'wait: [%4ds] %-12s  %s   live=%s%s\n' "$elapsed" "$status" "$now" "$live" "$canary_col"

  [ "$(date +%s)" -lt "$deadline" ] || die "deployment still $status after ${TIMEOUT}s"

  generate_load
  sleep 10
done
