#!/usr/bin/env bash
# Uploads the source corpus for one environment.
#
#   ENV=nonprod/dev bash pipelines/scripts/seed_corpus.sh                      # committed sample
#   ENV=nonprod/dev bash pipelines/scripts/seed_corpus.sh ~/wiki_movie_plots.csv
#
# The corpus lives under raw/ and is never expired by the lifecycle rule: indexes are rebuildable
# from it, but it is not rebuildable from them.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ENV_PATH="${ENV:-}"
SOURCE="${1:-$REPO_ROOT/data/raw/sample_movie_plots.csv}"
KEY="${CORPUS_KEY:-raw/movie_plots.csv}"

die() { printf 'seed: %s\n' "$*" >&2; exit 1; }

[ -n "$ENV_PATH" ] || die "ENV is required, e.g. ENV=nonprod/dev"
[ -f "$SOURCE" ] || die "corpus not found: $SOURCE"

ENV_DIR="$REPO_ROOT/infra/envs/$ENV_PATH"
bucket="$(terraform -chdir="$ENV_DIR" output -raw index_bucket 2>/dev/null)" \
  || die "cannot read index_bucket — has $ENV_PATH been deployed?"

rows="$(( $(wc -l < "$SOURCE") - 1 ))"
printf 'seed: uploading %s (%s rows) -> s3://%s/%s\n' "$(basename "$SOURCE")" "$rows" "$bucket" "$KEY"

if [ "$SOURCE" = "$REPO_ROOT/data/raw/sample_movie_plots.csv" ]; then
  printf 'seed: NOTE this is the committed smoke-test sample, not a real corpus.\n'
  printf '      For a realistic run, pass a Kaggle "Wikipedia Movie Plots" CSV as the argument.\n'
fi

aws s3 cp "$SOURCE" "s3://${bucket}/${KEY}"
printf 'seed: done. Build an index with the index workflow (action: build-and-promote).\n'
