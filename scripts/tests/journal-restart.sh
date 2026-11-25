#!/usr/bin/env bash
set -euo pipefail

# Exercises the real app process and download delegate in a disposable simulator.
# The fixture's journal writer alone refuses writes; the app store and audio
# directory remain writable. No existing simulator or app container is erased.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d /tmp/earshot-journal-restart.XXXXXX)"
simulator_id="$(xcrun simctl create "Earshot-Journal-Restart-$$" 'iPhone 17 Pro Max' \
    "${EARSHOT_JOURNAL_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}")"
cleanup() {
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Disposable simulator: $simulator_id"
echo "Build log: $scratch/build.log"
xcodebuild -project "$repo_root/Earshot.xcodeproj" -scheme Earshot \
    -configuration Debug -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$scratch/DerivedData" build > "$scratch/build.log" 2>&1 || {
    tail -40 "$scratch/build.log"
    exit 1
}
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b > "$scratch/boot.log" 2>&1
xcrun simctl install "$simulator_id" "$scratch/DerivedData/Build/Products/Debug-iphonesimulator/Earshot.app"
container="$(xcrun simctl get_app_container "$simulator_id" media.payown.earshot data)"
report="$container/Documents/journal-restart-probe.json"

wait_for_report() {
    local phase="$1"
    local old_mtime="${2:-0}"
    for _ in {1..60}; do
        if [[ -f "$report" ]] && [[ "$(stat -f %m "$report")" -gt "$old_mtime" ]] \
            && grep -q "\"phase\" : \"$phase\"" "$report"; then
            return 0
        fi
        sleep 1
    done
    echo "Timed out waiting for $phase report at $report" >&2
    exit 1
}

xcrun simctl launch "$simulator_id" media.payown.earshot -journalRestartProbeSeed
wait_for_report before-termination
python3 - "$report" "$container" seed <<'PY'
import json, pathlib, sys
report, container, stage = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
data = json.loads(report.read_text())
rows = {row['guid']: row for row in data['rows']}
assert len(data['files']) == 2, data
assert all(row['status'] == 'downloading' and not row['path'] for row in rows.values()), data
assert not (container / 'Library/Application Support/pending-download-events.json').exists(), data
assert all((container / 'Documents/Downloads' / name).is_file() for name in data['files']), data
print('Before termination: two audio files retained, journal refused, both rows downloading')
PY

xcrun simctl terminate "$simulator_id" media.payown.earshot
previous_mtime="$(stat -f %m "$report")"
sleep 1
xcrun simctl launch "$simulator_id" media.payown.earshot -journalRestartProbeVerify
wait_for_report relaunch "$previous_mtime"
python3 - "$report" "$container" relaunch <<'PY'
import json, pathlib, sys
report, container, stage = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
data = json.loads(report.read_text())
rows = {row['guid']: row for row in data['rows']}
current, superseded = rows['current'], rows['superseded']
assert current['status'] == 'downloaded' and current['path'] in data['files'], data
assert superseded['status'] == 'failed' and not superseded['path'], data
assert len(data['files']) == 2, data  # no unsolicited deletion
assert (container / 'Documents/Downloads' / current['path']).is_file(), data
assert current['attempt'] == '11111111-1111-4111-8111-111111111111', data
assert superseded['attempt'] == '33333333-3333-4333-8333-333333333333', data
print('Relaunch: current audio recovered; superseded attempt did not claim old audio')
PY

xcrun simctl terminate "$simulator_id" media.payown.earshot
previous_mtime="$(stat -f %m "$report")"
sleep 1
xcrun simctl launch "$simulator_id" media.payown.earshot -journalRestartProbeVerify
wait_for_report relaunch "$previous_mtime"
python3 - "$report" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
rows = {row['guid']: row for row in data['rows']}
assert rows['current']['status'] == 'downloaded' and rows['current']['path'] in data['files'], data
assert rows['superseded']['status'] == 'failed' and not rows['superseded']['path'], data
assert len(data['files']) == 2, data
print('Second relaunch: recovered ownership remains stable')
PY
