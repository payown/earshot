#!/usr/bin/env bash
# Usage: testflight [--notes "What to test"]
# Builds a release IPA and pushes it to the Internal Testing Group on TestFlight.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ASC_APP_ID="6770760602"
GROUP="Internal Testing Group"
NOTES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes|-n) NOTES="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

echo "▶ Building release IPA..."
flutter build ipa --release

echo "▶ Uploading to TestFlight..."
EXTRA_FLAGS=()
[[ -n "$NOTES" ]] && EXTRA_FLAGS+=(--test-notes "$NOTES" --locale en-US)

asc publish testflight \
  --app "$ASC_APP_ID" \
  --ipa "build/ios/ipa/earshot.ipa" \
  --group "$GROUP" \
  --wait \
  --notify \
  "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"

echo "✅ Done. Check TestFlight on your phone."
