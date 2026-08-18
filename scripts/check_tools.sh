#!/usr/bin/env bash
# Reports which tools this machine has. Exits non-zero only for tools that block local work —
# Docker is reported but never required, because images are built in CI.
set -uo pipefail

REQUIRED=0

check() {
  local name="$1" version_cmd="$2" requirement="$3" note="${4:-}"
  local path
  if path="$(command -v "$name" 2>/dev/null)"; then
    local version
    version="$($version_cmd 2>&1 | head -n1 | tr -d '\r')"
    printf '  %-10s %-9s %s\n' "$name" "ok" "$version"
  elif [ "$requirement" = "required" ]; then
    printf '  %-10s %-9s MISSING %s\n' "$name" "BLOCKED" "$note"
    REQUIRED=1
  else
    printf '  %-10s %-9s not installed %s\n' "$name" "-" "$note"
  fi
}

echo "Toolchain check"
echo

echo "Required for local development:"
check git        "git --version"          required
check terraform  "terraform version"      required
check aws        "aws --version"          required

echo
echo "Convenience:"
check make       "make --version"         optional "(Makefile targets wrap scripts/*.sh — call those directly instead)"

echo
echo "Optional:"
check docker     "docker --version"       optional "(images are built and pushed by GitHub Actions, not locally)"
check hadolint   "hadolint --version"     optional "(Dockerfile lint also runs in CI)"
check tflint     "tflint --version"       optional "(also runs in CI)"

echo
if [ -x .venv/Scripts/python.exe ]; then
  printf '  %-10s %-9s %s\n' "venv" "ok" "$(.venv/Scripts/python.exe --version 2>&1 | tr -d '\r')"
elif [ -x .venv/bin/python ]; then
  printf '  %-10s %-9s %s\n' "venv" "ok" "$(.venv/bin/python --version 2>&1 | tr -d '\r')"
else
  printf '  %-10s %-9s %s\n' "venv" "-" "not created — see README §4"
fi

echo
if [ "$REQUIRED" -ne 0 ]; then
  echo "Missing a required tool. See README §4."
  exit 1
fi
echo "Ready. Docker is not needed locally: release.yml builds and pushes every image."
