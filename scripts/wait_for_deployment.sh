#!/usr/bin/env bash
# Waits for one ECS deployment, and leaves behind evidence of what it did.
#
#   bash scripts/wait_for_deployment.sh <cluster> <service> <previous-arn> [base-url] [test-url]
#
# Shared because deploy.sh and promote_index.sh both start a deployment and both need the same
# answer. `aws ecs wait services-stable` cannot give it, for two reasons: its budget is a fixed
# 10 minutes, which is shorter than a gated release, and a deployment the alarms reversed reaches
# a steady state exactly like one that succeeded.
#
# The output is deliberately verbose where something is actually happening. A staged rollout is
# minutes of silence otherwise, and "the release looked hung so I cancelled it" is a real
# incident: every lifecycle stage, gate verdict and traffic shift is printed when it happens and
# repeated as a table in the job summary. A rolling update has none of that machinery, so it
# reports only its status rather than columns that would always read the same.
set -euo pipefail

CLUSTER="${1:-}"
SERVICE="${2:-}"
PREVIOUS="${3:-none}"
BASE_URL="${4:-}"
TEST_URL="${5:-}"
TIMEOUT="${DEPLOY_TIMEOUT_SECONDS:-3600}"
# Enough requests per poll that a 60-second alarm period has a population to work with. Alarms
# that cannot fire are decoration.
LOAD="${DEPLOY_LOAD_REQUESTS:-25}"

die() { printf 'wait: %s\n' "$*" >&2; exit 1; }

[ -n "$CLUSTER" ] || die "usage: wait_for_deployment.sh <cluster> <service> [previous-arn] [base-url] [test-url]"
[ -n "$SERVICE" ] || die "usage: wait_for_deployment.sh <cluster> <service> [previous-arn] [base-url] [test-url]"

BASE_URL="${BASE_URL%/}"
TEST_URL="${TEST_URL%/}"
TIMELINE="$(mktemp)"

# A test listener is what distinguishes the two strategies, so it is also what decides how much of
# this script is worth running.
STAGED=0
[ -n "$TEST_URL" ] && STAGED=1

# Reproduced into the job summary so the shifts survive after the log scrolls away.
emit_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  [ -s "$TIMELINE" ] || return 0
  {
    printf '\n#### Deployment timeline\n\n'
    if [ "$STAGED" = 1 ]; then
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
# usable here — ECS reports it as null even mid-deployment.
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
# neither retrieval nor Bedrock, which is also why it cannot judge answer quality — that is the
# deployment gate's job, and the alarms only cover errors and latency.
generate_load() {
  [ -n "$BASE_URL" ] || return 0
  local i
  for i in $(seq 1 "$LOAD"); do
    curl -fsS --max-time 5 -o /dev/null "$BASE_URL/healthz" 2>/dev/null || true &
  done
  wait
}

# Where ECS thinks it is, and what the gate said. Both come from the deployment itself rather than
# being inferred, so the log says "the gate rejected this" instead of "it rolled back, unclear why".
describe() {
  aws ecs describe-service-deployments --service-deployment-arns "$1" \
    --query 'serviceDeployments[0].[lifecycleStage,join(`/`,lifecycleHookDetails[].status) || `none`]' \
    --output text 2>/dev/null || printf -- '-\t-'
}

if [ "$STAGED" = 1 ]; then
  resolve_alb || printf 'wait: could not resolve the load balancer; traffic weights will not be reported\n'
fi

deadline=$(( $(date +%s) + TIMEOUT ))
started=$(date +%s)
last_weights=""
last_stage=""
last_hook=""

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
  live="$(release_at "$BASE_URL")"

  if [ "$STAGED" = 1 ]; then
    now="$(weights)"
    test_release="$(release_at "$TEST_URL")"
    detail="  $now   live=$live  test=$test_release"
    cell=" \`$test_release\` |"

    if [ "$status" != "REGISTERING" ]; then
      read -r stage hook <<EOF
$(describe "$deployment")
EOF
    else
      stage="-" hook="-"
    fi

    # The gate is the decision point, so it is called out by name rather than left as one more
    # stage. POST_TEST_TRAFFIC_SHIFT is where the golden set runs against the new task set.
    if [ "$stage" != "$last_stage" ] && [ "$stage" != "-" ]; then
      printf 'wait: >>> [%4ds] %-22s %s\n' "$elapsed" "$stage" "$detail"
      printf '| %ds | stage `%s` | `%s` |%s\n' "$elapsed" "$stage" "$live" "$cell" >> "$TIMELINE"
      last_stage="$stage"
    fi

    if [ "$hook" != "$last_hook" ] && [ "$hook" != "-" ] && [ "$hook" != "none" ]; then
      printf 'wait: >>> [%4ds] GATE %-17s %s\n' "$elapsed" "$hook" "$detail"
      printf '| %ds | **gate %s** | `%s` |%s\n' "$elapsed" "$hook" "$live" "$cell" >> "$TIMELINE"
      last_hook="$hook"
    fi

    # Only transitions are worth reporting; the polls between them are noise. The first reading is
    # the state we started from rather than a shift.
    if [ "$now" != "$last_weights" ]; then
      if [ -z "$last_weights" ]; then event="baseline"; else event="TRAFFIC SHIFT"; fi
      printf 'wait: >>> [%4ds] %-22s %s\n' "$elapsed" "$event" "$detail"
      printf '| %ds | %s → %s | `%s` |%s\n' "$elapsed" "$event" "$now" "$live" "$cell" >> "$TIMELINE"
      last_weights="$now"
    fi
  else
    # A rolling update never moves traffic between target groups and runs no hooks, so weights and
    # a test column would be constants. Status and the live release are the whole story.
    detail="  live=$live"
    cell=""
  fi

  case "$status" in
    SUCCESSFUL)
      printf 'wait: [%4ds] SUCCEEDED %s\n' "$elapsed" "$detail"
      printf '| %ds | **deployment succeeded** | `%s` |%s\n' "$elapsed" "$live" "$cell" >> "$TIMELINE"
      exit 0
      ;;
    ROLLBACK_SUCCESSFUL | ROLLBACK_IN_PROGRESS)
      printf 'wait: [%4ds] ROLLING BACK %s\n' "$elapsed" "$detail"
      printf '| %ds | **ROLLED BACK** (%s) | `%s` |%s\n' "$elapsed" "$status" "$live" "$cell" >> "$TIMELINE"
      die "ECS is reversing this deployment ($status) — the previous version is what is serving"
      ;;
    ROLLBACK_FAILED | STOPPED | STOP_REQUESTED)
      printf '| %ds | **%s** | `%s` |%s\n' "$elapsed" "$status" "$live" "$cell" >> "$TIMELINE"
      die "deployment ended as $status"
      ;;
  esac

  printf 'wait: [%4ds] %-12s %s\n' "$elapsed" "$status" "$detail"

  [ "$(date +%s)" -lt "$deadline" ] || die "deployment still $status after ${TIMEOUT}s"

  generate_load
  sleep 10
done
