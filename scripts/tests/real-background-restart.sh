#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d /tmp/earshot-real-download.XXXXXX)"
simulator_id="$(xcrun simctl create "Earshot-Real-Background-$$" 'iPhone 17 Pro Max' com.apple.CoreSimulator.SimRuntime.iOS-26-5)"
server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" >/dev/null 2>&1 || true
        wait "$server_pid" 2>/dev/null || true
    fi
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$scratch/server.key" -out "$scratch/server.crt" \
    -subj '/CN=127.0.0.1' -addext 'subjectAltName=IP:127.0.0.1' \
    > "$scratch/openssl.log" 2>&1
python3 - "$scratch" <<'PY' > "$scratch/server.log" 2>&1 &
import http.server, pathlib, socketserver, ssl, sys
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'ID3' + b'\x00' * 65536
        self.send_response(200)
        self.send_header('Content-Type', 'audio/mpeg')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, format, *args):
        print(format % args, flush=True)
server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(root / 'server.crt', root / 'server.key')
server.socket = context.wrap_socket(server.socket, server_side=True)
(root / 'port').write_text(str(server.server_address[1]))
server.serve_forever()
PY
server_pid="$!"
for _ in {1..90}; do [[ -s "$scratch/port" ]] && break; sleep 1; done
[[ -s "$scratch/port" ]]
port="$(cat "$scratch/port")"
echo "Disposable simulator: $simulator_id; local TLS port: $port; scratch: $scratch"

xcodebuild -project "$repo_root/Earshot.xcodeproj" -scheme Earshot \
    -configuration Debug -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$scratch/DerivedData" build > "$scratch/build.log" 2>&1 || {
    tail -60 "$scratch/build.log"; exit 1;
}
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b > "$scratch/boot.log" 2>&1
xcrun simctl keychain "$simulator_id" add-root-cert "$scratch/server.crt"
xcrun simctl install "$simulator_id" "$scratch/DerivedData/Build/Products/Debug-iphonesimulator/Earshot.app"
container="$(xcrun simctl get_app_container "$simulator_id" media.payown.earshot data)"
report="$container/Documents/real-download-restart-probe.json"

wait_phase() {
    local phase="$1" old_mtime="${2:-0}"
    for _ in {1..60}; do
        if [[ -f "$report" ]] && [[ "$(stat -f %m "$report")" -gt "$old_mtime" ]] \
            && grep -q "\"phase\" : \"$phase\"" "$report"; then return 0; fi
        sleep 1
    done
    echo "Timed out waiting for $phase" >&2
    cat "$report" "$scratch/server.log" 2>/dev/null || true
    exit 1
}

xcrun simctl launch "$simulator_id" media.payown.earshot \
    -journalRestartRealSeed -journalRestartRealURL "https://127.0.0.1:$port/audio.mp3"
wait_phase callback
python3 - "$report" "$container" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
container = pathlib.Path(sys.argv[2])
assert data['status'] == 'downloading' and not data['path'], data
assert len(data['files']) == 1, data
assert not (container / 'Library/Application Support/pending-download-events.json').exists(), data
assert (container / 'Documents/Downloads' / data['files'][0]).is_file(), data
print('OS background URLSession callback moved audio; refused journal left row downloading')
PY

xcrun simctl terminate "$simulator_id" media.payown.earshot
old_mtime="$(stat -f %m "$report")"
sleep 1
xcrun simctl launch "$simulator_id" media.payown.earshot -journalRestartRealVerify
wait_phase relaunch "$old_mtime"
python3 - "$report" "$container" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
container = pathlib.Path(sys.argv[2])
assert data['status'] == 'downloaded' and data['path'] in data['files'], data
assert len(data['files']) == 1, data
assert (container / 'Documents/Downloads' / data['path']).is_file(), data
print('Relaunch recovered OS-delivered audio and current attempt ownership')
PY
