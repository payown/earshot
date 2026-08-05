#!/usr/bin/env bash

set -o pipefail

SCRIPT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  REPO_ROOT="$SCRIPT_REPO_ROOT"
fi
CI_SIMULATOR_NAME="CI-iPhone-17"
CI_SIMULATOR_UDID="23F12FE1-0D77-4B42-B766-ADD9F27A2153"
CI_DEVICE_TYPE="iPhone 17"
CI_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/earshot-local-ci.XXXXXX")"

print_failure() {
  local reason="$1"

  printf '\nLocal CI summary\n'
  printf 'Result: FAIL\n'
  printf 'Reason: %s\n' "$reason"
  printf 'Log: %s\n' "$LOG_FILE"
}

cd "$REPO_ROOT" || {
  print_failure "Could not enter repository root: $REPO_ROOT"
  exit 1
}

printf '==> Xcode version\n'
if ! xcodebuild -version; then
  print_failure "xcodebuild -version failed"
  exit 1
fi

printf '\n==> Checking dedicated CI simulator\n'
if ! xcrun simctl list devices | grep "$CI_SIMULATOR_UDID"; then
  printf 'Dedicated CI simulator %s (%s) is missing.\n' \
    "$CI_SIMULATOR_NAME" "$CI_SIMULATOR_UDID"
  printf 'Recreating %s with device type %s and runtime %s...\n' \
    "$CI_SIMULATOR_NAME" "$CI_DEVICE_TYPE" "$CI_RUNTIME"

  if ! replacement_udid="$(
    xcrun simctl create \
      "$CI_SIMULATOR_NAME" \
      "$CI_DEVICE_TYPE" \
      "$CI_RUNTIME"
  )"; then
    print_failure "Could not recreate the dedicated CI simulator"
    exit 1
  fi

  CI_SIMULATOR_UDID="$replacement_udid"
  printf 'Created replacement simulator with UDID %s.\n' "$CI_SIMULATOR_UDID"
  printf 'The workflow UDID must be updated before GitHub Actions can use it.\n'
fi

printf '\n==> Running EarshotTests\n'
set +e
TEST_RUNNER_EARSHOT_SKIP_STOREKIT_TESTS="1" \
  xcodebuild test \
    -project Earshot.xcodeproj \
    -scheme Earshot \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$CI_SIMULATOR_UDID" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    2>&1 | tee "$LOG_FILE"
test_status=${PIPESTATUS[0]}

test_summary="$(
  awk '/Executed [0-9]+ tests?/ { summary = $0 }
       END {
         sub(/^[[:space:]]*/, "", summary)
         print summary
       }' "$LOG_FILE"
)"

tests="unknown"
skipped="unknown"
failures="unknown"
if [[ "$test_summary" =~ Executed[[:space:]]+([0-9]+)[[:space:]]+tests?,[[:space:]]+with[[:space:]]+([0-9]+)[[:space:]]+tests?[[:space:]]+skipped[[:space:]]+and[[:space:]]+([0-9]+)[[:space:]]+failures? ]]; then
  tests="${BASH_REMATCH[1]}"
  skipped="${BASH_REMATCH[2]}"
  failures="${BASH_REMATCH[3]}"
elif [[ "$test_summary" =~ Executed[[:space:]]+([0-9]+)[[:space:]]+tests?,[[:space:]]+with[[:space:]]+([0-9]+)[[:space:]]+failures? ]]; then
  tests="${BASH_REMATCH[1]}"
  skipped="0"
  failures="${BASH_REMATCH[2]}"
fi

printf '\nLocal CI summary\n'
if [[ $test_status -eq 0 ]]; then
  printf 'Result: PASS\n'
else
  printf 'Result: FAIL\n'
fi
printf 'Tests: %s executed, %s skipped, %s failed\n' \
  "$tests" "$skipped" "$failures"
printf 'Simulator: %s (%s)\n' "$CI_SIMULATOR_NAME" "$CI_SIMULATOR_UDID"
printf 'Log: %s\n' "$LOG_FILE"

exit "$test_status"
