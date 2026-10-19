#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
check_root="$PWD/work/update-checks"
mkdir -p "$check_root/ModuleCache"
check_root="$(cd "$check_root" && pwd -P)"
export CLANG_MODULE_CACHE_PATH="$check_root/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift_build=(swift build --scratch-path "$check_root/build" --disable-sandbox --cache-path "$check_root/build/cache" \
    --config-path "$check_root/build/configuration" --security-path "$check_root/build/security")
"${swift_build[@]}" --target QuietDeskCore
build_directory="$("${swift_build[@]}" --show-bin-path)"
check_app="$check_root/UpdateInstallerChecks.app"
mkdir -p "$check_app/Contents/MacOS"
cat > "$check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.quietdesk.checks.updater</string>
<key>CFBundleName</key><string>QuietDesk Update Checks (Synthetic State)</string>
<key>CFBundleExecutable</key><string>UpdateInstallerChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleVersion</key><string>0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
core_objects=("$build_directory"/QuietDeskCore.build/*.swift.o)
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$check_root/ModuleCache" -I "$build_directory/Modules" \
    "${core_objects[@]}" Sources/QuietDesk/AppDataLocation.swift Sources/QuietDesk/UpdateInstaller.swift \
    AppChecks/UpdateInstallerChecks.swift -o "$check_app/Contents/MacOS/UpdateInstallerChecks"
codesign --force --sign - "$check_app"
if [[ $# -gt 0 ]]; then
    "$check_app/Contents/MacOS/UpdateInstallerChecks" "$@"
    exit
fi
cat > "$check_root/server.py" <<'PY'
import http.server
import pathlib
import sys
import time
import urllib.parse

root = pathlib.Path(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        request_path = urllib.parse.urlsplit(self.path).path
        if request_path == '/insecure-redirect':
            self.send_response(302)
            self.send_header('Location', 'http://example.invalid/archive.zip')
            self.end_headers()
            return
        path = request_path.removeprefix('/slow/').removeprefix('/unknown/').removeprefix('/')
        if '/' in path or path not in ('archive.zip', 'manifest.json'):
            self.send_error(404)
            return
        data = (root / path).read_bytes()
        self.send_response(200)
        if not request_path.startswith('/unknown/'):
            self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            for offset in range(0, len(data), 4096):
                self.wfile.write(data[offset:offset + 4096])
                self.wfile.flush()
                if request_path.startswith('/slow/'):
                    time.sleep(0.02)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'server-port').write_text(str(server.server_port))
server.serve_forever()
PY
rm -f "$check_root/server-port"
python3 "$check_root/server.py" "$check_root" > "$check_root/server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for _ in {1..100}; do
    if [[ -f "$check_root/server-port" ]]; then break; fi
    sleep 0.05
done
if [[ ! -f "$check_root/server-port" ]]; then
    cat "$check_root/server.log" >&2
    exit 1
fi
export QUIETDESK_UPDATE_CHECK_ROOT="$check_root"
export QUIETDESK_UPDATE_CHECK_URL="http://127.0.0.1:$(cat "$check_root/server-port")"
"$check_app/Contents/MacOS/UpdateInstallerChecks"
