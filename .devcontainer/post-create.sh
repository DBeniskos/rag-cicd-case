#!/usr/bin/env bash
# Runs once when the dev container is created.
set -euo pipefail

echo "Installing Python dependencies..."
pip install --no-cache-dir --upgrade pip
pip install --no-cache-dir -r requirements-dev.txt -r app/api/requirements.txt

# Ingest ships its own requirements once the job exists.
if [ -f app/ingest/requirements.txt ]; then
  pip install --no-cache-dir -r app/ingest/requirements.txt
fi

chmod +x pipelines/scripts/*.sh 2>/dev/null || true

echo
bash pipelines/scripts/check_tools.sh || true

cat <<'EOF'

Dev container ready.

  make test              run the test suite
  make lint              ruff + format check
  aws configure sso      or export AWS_* credentials, then: bash pipelines/scripts/bootstrap.sh

Docker is available here, so local image builds work:
  docker build -f app/api/Dockerfile -t rag-api:dev .
EOF
