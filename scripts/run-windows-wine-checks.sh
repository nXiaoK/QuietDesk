#!/bin/bash
# Runs the cross-built Windows platform code under Wine in a container: screen capture, the Media Foundation
# encoder and decoder, and a host and a viewer of the Windows build connected to each other. Wine stands in
# for Windows here; its capture path is GDI and its codecs are GStreamer's, not the ones Windows ships.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-windows.sh --build-only
source scripts/windows-toolchain.sh
# Cargo identifies the current test executable even when older builds share the same cache.
native_test="$(cd windows && cargo test --locked --target x86_64-pc-windows-gnullvm --release -p quietdesk-app --lib --no-run --message-format=json | python3 -c '
import json, sys
builds = (json.loads(line) for line in sys.stdin)
binary, = [row["executable"] for row in builds
           if row.get("executable") and "lib" in row["target"]["kind"] and row["profile"]["test"]]
print(binary)
')"
image=quietdesk-wine-check:local
docker image inspect "$image" >/dev/null 2>&1 || docker build --platform linux/amd64 -t "$image" -f windows/wine-check.Dockerfile windows >/dev/null
export QUIETDESK_WINCHECK_PAIRING_CODE="$(python3 -c 'import os; print(os.urandom(32).hex())')"
# Limit only this container when testing Wine under a CPU translator.
container_args=(--rm --init --network none --platform linux/amd64)
if [[ -n "${QUIETDESK_WINE_CPUSET:-}" ]]; then container_args+=(--cpuset-cpus "$QUIETDESK_WINE_CPUSET"); fi
# The clipboard checks own their Wine prefix and desktop. The media run gets a fresh one.
docker run -i "${container_args[@]}" -v "$native_test:/qa/native-tests.exe:ro" "$image" bash -s <<'NATIVE_CHECKS'
set -eu
export LC_ALL=C.UTF-8 XDG_RUNTIME_DIR=/tmp DISPLAY=:99 WINEDEBUG=-all QUIETDESK_ISOLATED_CLIPBOARD_CHECK=1
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
sleep 2
timeout 120 wineboot -i >/dev/null 2>&1
timeout 90 wine /qa/native-tests.exe --test-threads=1
timeout 60 wine /qa/native-tests.exe clipboard_native_ --ignored --test-threads=1
NATIVE_CHECKS

docker run -i "${container_args[@]}" -e QUIETDESK_WINCHECK_PAIRING_CODE -v "$CARGO_TARGET_DIR/x86_64-pc-windows-gnullvm/release:/app:ro" "$image" bash -s <<'WINE_CHECKS'
{
set -o pipefail
export LC_ALL=C.UTF-8 XDG_RUNTIME_DIR=/tmp DISPLAY=:99 WINEDEBUG=-all
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
sleep 2
timeout 120 wineboot -i >/dev/null 2>&1
check=/app/quietdesk-wincheck.exe
# A moving picture: Wine holds frames back in its codecs, which a still screen would never fill.
(timeout 150 wine clock >/dev/null 2>&1 &)
sleep 6
failed=0
timeout 60 wine $check capture 2>/dev/null | grep -E "^(PASS|FAIL)" || failed=1
timeout 45 wine $check displays 2>/dev/null | grep -E "^(PASS|FAIL)" || failed=1
timeout 30 wine $check cursor 2>/dev/null | grep -E "^(PASS|FAIL)" || failed=1
timeout 90 wine $check codec --frames 240 2>/dev/null | grep -E "^(codec|PASS|FAIL)" || failed=1
# Start with a closed port so the packaged viewer must reconnect before it can receive video and a cursor.
timeout 75 wine $check viewer --port 45990 --seconds 40 --require-media --require-cursor --require-reconnect --require-display >/tmp/viewer.log 2>&1 &
viewer_pid=$!
for tick in {1..20}; do
    grep -q "^viewer waiting for retry" /tmp/viewer.log && break
    kill -0 "$viewer_pid" 2>/dev/null || break
    sleep 1
done
(timeout 80 wine $check host --port 45990 --seconds 70 >/tmp/host.log 2>&1 &)
if ! wait "$viewer_pid"; then
    grep -E "^((INFO|WARN|ERROR) \[quietdesk_(core::media|windows::win::(pipeline|codec|app))\]|host Ended|rosetta error:)" /tmp/host.log /tmp/viewer.log | tail -35 >&2
    failed=1
fi
grep -E "^(viewer ended|PASS|FAIL)" /tmp/viewer.log
awk '
function measured(value, calls) {
    return calls > 0 ? value ~ /^[0-9]+([.][0-9]+)?$/ : value == "na"
}
BEGIN {
    split("window_ms capture_calls changed convert_calls encode_calls repeats output queued dropped", counters)
}
/host video stats / {
    sub(/^.*host video stats /, "")
    sub(/\r$/, "")
    delete metric
    for (i = 1; i <= NF; i++) {
        split($i, pair, "=")
        metric[pair[1]] = pair[2]
    }
    windows++
    for (i in counters) if (metric[counters[i]] !~ /^[0-9]+$/) invalid = 1
    capture = metric["capture_calls"] + 0
    convert = metric["convert_calls"] + 0
    encode = metric["encode_calls"] + 0
    if (metric["window_ms"] + 0 < 1000 || metric["source"] !~ /^(gdi|dxgi|mixed)$/ ||
        metric["changed"] + 0 > capture || convert + metric["repeats"] != encode ||
        metric["queued"] + metric["dropped"] != metric["output"] + 0) invalid = 1
    if (!measured(metric["capture_avg_ms"], capture) || !measured(metric["capture_work_avg_ms"], capture) ||
        !measured(metric["capture_wait_avg_ms"], capture) || !measured(metric["convert_avg_ms"], convert) ||
        !measured(metric["encode_avg_ms"], encode) ||
        (metric["process_cpu_ms_per_s"] != "na" && !measured(metric["process_cpu_ms_per_s"], 1))) invalid = 1
    if (metric["capture_avg_ms"] + 0 > 0 && metric["convert_avg_ms"] + 0 > 0 && metric["encode_avg_ms"] + 0 > 0 && !sample) {
        sample = sprintf("window_ms=%d source=%s capture_avg_ms=%s convert_avg_ms=%s encode_avg_ms=%s process_cpu_ms_per_s=%s",
                         metric["window_ms"], metric["source"], metric["capture_avg_ms"], metric["convert_avg_ms"], metric["encode_avg_ms"], metric["process_cpu_ms_per_s"])
    }
    if (!idle && (metric["repeats"] + 0 > 0 || encode == 0))
        idle = sprintf("window_ms=%d changed=%d repeats=%d queued=%d", metric["window_ms"], metric["changed"], metric["repeats"], metric["queued"])
    for (i in counters) total[counters[i]] += metric[counters[i]]
}
END {
    if (invalid || windows < 2 || !sample || !total["changed"] || !total["queued"]) {
        printf "FAIL host video stats windows=%d inconsistent=%d changed=%d queued=%d\n", windows, invalid, total["changed"], total["queued"]
        exit 1
    }
    printf "PASS host video stats windows=%d capture_calls=%d convert_calls=%d encode_calls=%d queued=%d dropped=%d %s\n",
           windows, total["capture_calls"], total["convert_calls"], total["encode_calls"], total["queued"], total["dropped"], sample
    if (idle) print "host idle or repeat window " idle
}' /tmp/host.log || failed=1
exit $failed
} </dev/null
WINE_CHECKS
