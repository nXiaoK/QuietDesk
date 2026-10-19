#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../relay"
export GOCACHE="${QUIETDESK_RELAY_GO_CACHE:-$PWD/../work/relay-build/go-cache}"
mkdir -p "$GOCACHE"
go vet ./...
go test -race -count=1 -timeout=60s ./...
