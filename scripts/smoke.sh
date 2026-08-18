#!/usr/bin/env bash
# Proves a deployment is serving what the pipeline intended.
#
#   bash scripts/smoke.sh <base-url> [expected-release]
#
# Checked rather than assumed: a deploy can report success while the load balancer still routes to
# the previous task set, and "the pipeline went green" is not evidence that anything changed.
set -euo pipefail

BASE_URL="${1:-}"
EXPECTED_RELEASE="${2:-}"
TIMEOUT="${SMOKE_TIMEOUT:-10}"
RETRIES="${SMOKE_RETRIES:-20}"
SLEEP_SECONDS="${SMOKE_SLEEP:-5}"

die() { printf 'smoke: %s\n' "$*" >&2; exit 1; }

[ -n "$BASE_URL" ] || die "usage: smoke.sh <base-url> [expected-release]"
command -v curl >/dev/null 2>&1 || die "curl not found"

BASE_URL="${BASE_URL%/}"

# Targets register with the load balancer asynchronously, so the first requests after a deploy
# legitimately fail. Retrying distinguishes "not ready yet" from "broken".
printf 'smoke: waiting for %s/healthz\n' "$BASE_URL"
attempt=1
until curl -fsS --max-time "$TIMEOUT" "$BASE_URL/healthz" >/dev/null 2>&1; do
  [ "$attempt" -lt "$RETRIES" ] || die "healthz never became available after $((RETRIES * SLEEP_SECONDS))s"
  attempt=$((attempt + 1))
  sleep "$SLEEP_SECONDS"
done
printf 'smoke: healthz ok after %d attempt(s)\n' "$attempt"

version_json="$(curl -fsS --max-time "$TIMEOUT" "$BASE_URL/version")" || die "/version unreachable"
printf 'smoke: %s\n' "$version_json"

field() {
  printf '%s' "$version_json" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

running_release="$(field release)"
index_version="$(field index_version)"

[ -n "$running_release" ] || die "/version did not report a release"

# The assertion that makes promotion verifiable: dev and prod must be running the same bytes,
# and this is the only place that is actually confirmed.
if [ -n "$EXPECTED_RELEASE" ] && [ "$running_release" != "$EXPECTED_RELEASE" ]; then
  die "expected release '$EXPECTED_RELEASE' but '$running_release' is serving — traffic did not shift"
fi

# A freshly provisioned environment legitimately has no index; that is a warning, not a failure,
# because the service is healthy and the index promotion is a separate pipeline.
if [ "$index_version" = "none" ] || [ -z "$index_version" ]; then
  printf 'smoke: WARNING no index promoted — /ask will return 503 until index.yml runs\n'
else
  printf 'smoke: serving index %s\n' "$index_version"
fi

printf 'smoke: pass (release=%s)\n' "$running_release"
