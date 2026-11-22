#!/bin/bash
# Runs the cross-built Windows platform code under Wine in a container: screen capture, the Media Foundation
# encoder and decoder, and a host and a viewer of the Windows build connected to each other. Wine stands in
# for Windows here; its capture path is GDI and its codecs are GStreamer's, not the ones Windows ships.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-windows.sh --build-only
source scripts/windows-toolchain.sh
image=quietdesk-wine-check:local
docker image inspect "$image" >/dev/null 2>&1 || docker build --platform linux/amd64 -t "$image" -f windows/wine-check.Dockerfile windows >/dev/null
code="$(python3 -c 'import os; print(os.urandom(32).hex())')"
docker run --rm --init --platform linux/amd64 -v "$CARGO_TARGET_DIR/x86_64-pc-windows-gnullvm/release:/app:ro" "$image" bash -c '
set -o pipefail
export XDG_RUNTIME_DIR=/tmp DISPLAY=:99 WINEDEBUG=-all
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
sleep 2
timeout 120 wineboot -i >/dev/null 2>&1
check=/app/quietdesk-wincheck.exe
# A moving picture: Wine holds frames back in its codecs, which a still screen would never fill.
(timeout 150 wine clock >/dev/null 2>&1 &)
sleep 6
failed=0
timeout 60 wine $check capture 2>/dev/null | grep -E "^(PASS|FAIL)" || failed=1
timeout 90 wine $check codec --frames 240 2>/dev/null | grep -E "^(codec|PASS|FAIL)" || failed=1
(timeout 80 wine $check host --code '"$code"' --port 45990 --seconds 70 >/tmp/host.log 2>&1 &)
sleep 6
if ! timeout 70 wine $check viewer --code '"$code"' --port 45990 --seconds 30 --require-media 2>/tmp/viewer.log | grep -E "^(viewer ended|PASS|FAIL)"; then
    grep -E "^((INFO|WARN|ERROR) \[quietdesk_(core::media|windows::win::(pipeline|codec|app))\]|host Ended|rosetta error:)" /tmp/host.log /tmp/viewer.log | tail -35 >&2
    failed=1
fi
exit $failed'
