#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../relay"
relay_output="${QUIETDESK_RELAY_DIST_DIR:-$PWD/../outputs/relay}"
export GOCACHE="${QUIETDESK_RELAY_GO_CACHE:-$PWD/../work/relay-build/go-cache}"
mkdir -p "$relay_output" "$GOCACHE"
for relay_arch in amd64 arm64; do
    CGO_ENABLED=0 GOOS=linux GOARCH="$relay_arch" go build -trimpath -buildvcs=false \
        -o "$relay_output/quietdesk-relay-linux-$relay_arch" ./cmd/quietdesk-relay
done
cp README.md quietdesk-relay.service ../LICENSE "$relay_output/"
python3 ../scripts/package-relay.py "$relay_output"
