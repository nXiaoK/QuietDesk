#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_root="${QUIETDESK_CHECK_BUILD_DIR:-$PWD/work/update-controller-checks}"
export CLANG_MODULE_CACHE_PATH="$check_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$check_root/home/Library/Logs"
swift_build=(swift build --scratch-path "$check_root" --disable-sandbox --cache-path "$check_root/cache" \
    --config-path "$check_root/configuration" --security-path "$check_root/security")
"${swift_build[@]}" --target QuietDeskCore
build_directory="$("${swift_build[@]}" --show-bin-path)"
core_objects=("$build_directory"/QuietDeskCore.build/*.swift.o)
check_app="$check_root/UpdateControllerChecks.app"
mkdir -p "$check_app/Contents/MacOS"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_directory/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" Sources/QuietDesk/AppDataLocation.swift Sources/QuietDesk/DiagnosticLog.swift \
    Sources/QuietDesk/UpdateController.swift Sources/QuietDesk/UpdateView.swift AppChecks/UpdateControllerChecks.swift \
    -o "$check_app/Contents/MacOS/UpdateControllerChecks"
python3 - "$check_app/Contents/Info.plist" <<'PY'
from pathlib import Path
import plistlib
import sys
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "local.quietdesk.checks.updater",
    "CFBundleName": "QuietDesk Synthetic Update Checks",
    "CFBundleExecutable": "UpdateControllerChecks",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.7.0",
    "CFBundleVersion": "30",
    "LSUIElement": True,
    "LSMinimumSystemVersion": "14.0",
}))
PY
plutil -lint "$check_app/Contents/Info.plist"
codesign --force --sign - "$check_app"
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
mkdir -p "$check_root/http-root"
port_file="$check_root/http-root/port.txt"
rm -f "$port_file"
python3 -u - "$check_root/http-root" "$port_file" > "$check_root/http-server.log" 2>&1 <<'PYHTTP' &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import time

root = Path(sys.argv[1])
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        if self.headers.get("User-Agent") != "QuietDesk/0.7.0":
            self.send_error(400)
            return
        if self.path == "/missing":
            self.send_error(404)
            return
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "http://192.0.2.1/insecure")
            self.end_headers()
            return
        if self.path == "/cookies" and self.headers.get("Cookie"):
            self.send_error(400)
            return
        self.send_response(200)
        self.send_header("Set-Cookie", "quietdesk-fixture=should-not-persist")
        if self.path == "/oversized-header":
            self.send_header("Content-Length", "65537")
            self.end_headers()
            return
        self.end_headers()
        if self.path == "/slow":
            time.sleep(17)
        data = b" " * 65537 if self.path == "/oversized-stream" else (root / "feed.json").read_bytes()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[2]).write_text(str(server.server_address[1]))
server.serve_forever()
PYHTTP
http_server_pid=$!
cleanup() {
    kill "$http_server_pid" 2>/dev/null || true
    wait "$http_server_pid" 2>/dev/null || true
    rm -f "$port_file" "$check_root/http-root/feed.json"
}
trap cleanup EXIT
for _ in {1..100}; do
    if [[ -s "$port_file" ]]; then break; fi
    if ! kill -0 "$http_server_pid" 2>/dev/null; then cat "$check_root/http-server.log"; exit 1; fi
    sleep 0.05
done
if [[ ! -s "$port_file" ]]; then echo "Loopback fixture did not start" >&2; exit 1; fi
read -r http_port < "$port_file" || true
CFFIXED_USER_HOME="$check_root/home" QUIETDESK_UPDATE_CONTROLLER_CHECK_ROOT="$check_root" \
    QUIETDESK_UPDATE_CONTROLLER_CHECK_FEED="http://127.0.0.1:$http_port" \
    "$check_app/Contents/MacOS/UpdateControllerChecks"
