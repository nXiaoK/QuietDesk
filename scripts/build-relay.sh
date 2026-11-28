#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../relay"
relay_output="${QUIETDESK_RELAY_DIST_DIR:-$PWD/../outputs/relay}"
relay_version="${QUIETDESK_VERSION:-}"
if [[ -z "$relay_version" ]]; then
    relay_version="$(python3 -c 'import json; print(json.load(open("../version.json"))["version"])')"
fi
export GOCACHE="${QUIETDESK_RELAY_GO_CACHE:-$PWD/../work/relay-build/go-cache}"
mkdir -p "$relay_output" "$GOCACHE"
for relay_arch in amd64 arm64; do
    CGO_ENABLED=0 GOOS=linux GOARCH="$relay_arch" go build -trimpath -buildvcs=false \
        -ldflags "-X quietdesk/relay.ServerVersion=$relay_version" \
        -o "$relay_output/quietdesk-relay-linux-$relay_arch" ./cmd/quietdesk-relay
done
cp README.md quietdesk-relay.service ../LICENSE "$relay_output/"
QUIETDESK_VERSION="$relay_version" python3 ../scripts/package-relay.py "$relay_output"
