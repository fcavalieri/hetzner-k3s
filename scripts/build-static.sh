#!/usr/bin/env bash
# Static linux/amd64 binary, like upstream's release job. Output: dist/hetzner-k3s
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
rm -f dist/hetzner-k3s
docker run --rm -v "$PWD":/app -w /app -e HOME=/tmp -e CRYSTAL_CACHE_DIR=/tmp/crystal-cache \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  crystallang/crystal:1.20.2-alpine sh -euc '
    apk add --no-cache gmp-dev gmp-static >/dev/null
    shards install --without-development
    crystal build src/hetzner-k3s.cr --release --static -o dist/hetzner-k3s
    chown "$HOST_UID:$HOST_GID" dist/hetzner-k3s
    chown -R "$HOST_UID:$HOST_GID" lib 2>/dev/null || true'
file dist/hetzner-k3s | grep -q 'statically linked' || { echo "dist/hetzner-k3s is not statically linked" >&2; exit 1; }
ls -la dist/hetzner-k3s
