#!/usr/bin/env bash
# Run crystal/shards in the pinned image. Usage: scripts/crystal-docker.sh spec | build ... | shards install
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${CRYSTAL_IMAGE:-crystallang/crystal:1.20.2}"
mkdir -p .crystal-cache
run() {
  docker run --rm -v "$PWD":/app -w /app -v "$PWD/.crystal-cache":/tmp/crystal-cache \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e CRYSTAL_CACHE_DIR=/tmp/crystal-cache "$IMAGE" "$@"
}
[ -d lib ] || run shards install --without-development
case "${1:-}" in
  shards) shift; run shards "$@" ;;
  *) run crystal "$@" ;;
esac
