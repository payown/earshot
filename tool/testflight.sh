#!/usr/bin/env bash
# Deploy to TestFlight.
# Usage: testflight [--notes "What to test"] [--public] [--both]
#
#   (no flag)  Upload to Internal Testing Group only
#   --public   Upload to Public Testers only
#   --both     Upload to both groups in a single build (same build number)
#
# What this does:
#   1. Verifies the working tree is clean and in sync with remote
#   2. Bumps the build number in pubspec.yaml and commits it
#   3. Builds a release IPA
#   4. Uploads to the specified TestFlight group(s)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ASC_APP_ID="6770760602"
GROUP="Internal Testing Group"
SUBMIT_FOR_REVIEW=false
NOTES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes|-n) NOTES="$2"; shift 2 ;;
    --public)   GROUP="Public Testers"; SUBMIT_FOR_REVIEW=true; shift ;;
    --both)     GROUP="Internal Testing Group,Public Testers"; SUBMIT_FOR_REVIEW=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Safety checks ────────────────────────────────────────────────────────────
BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [[ -n "$(git status --porcelain)" ]]; then
  echo "❌ Uncommitted changes. Commit or stash before deploying."
  exit 1
fi

git fetch origin "$BRANCH" --quiet 2>/dev/null || true
REMOTE_SHA=$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo "")
if [[ -n "$REMOTE_SHA" ]]; then
  LOCAL=$(git rev-parse HEAD)
  if [[ "$LOCAL" != "$REMOTE_SHA" ]]; then
    echo "❌ Local '$BRANCH' is out of sync with origin. Push or pull first."
    exit 1
  fi
fi

# ── Bump build number ─────────────────────────────────────────────────────────
CURRENT_VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //')
MARKETING=$(echo "$CURRENT_VERSION" | cut -d'+' -f1)
BUILD=$(echo "$CURRENT_VERSION" | cut -d'+' -f2)
NEXT_BUILD=$((BUILD + 1))
NEW_VERSION="${MARKETING}+${NEXT_BUILD}"

sed -i '' "s/^version: .*/version: $NEW_VERSION/" pubspec.yaml
git add pubspec.yaml
git commit -m "chore: bump build number to $NEXT_BUILD for TestFlight"
git push origin "$BRANCH"

echo "▶ Version: $NEW_VERSION"

# ── Build ─────────────────────────────────────────────────────────────────────
echo "▶ Building release IPA..."
flutter build ipa --release

# ── Upload ────────────────────────────────────────────────────────────────────
echo "▶ Uploading to TestFlight..."
EXTRA_FLAGS=()
[[ -n "$NOTES" ]]          && EXTRA_FLAGS+=(--test-notes "$NOTES" --locale en-US)
[[ "$SUBMIT_FOR_REVIEW" == true ]] && EXTRA_FLAGS+=(--submit --confirm)

TMP_OUTPUT=$(mktemp)
asc publish testflight \
  --app "$ASC_APP_ID" \
  --ipa "build/ios/ipa/earshot.ipa" \
  --group "$GROUP" \
  --wait \
  --notify \
  "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}" | tee "$TMP_OUTPUT"

ASC_BUILD=$(grep -o '"buildNumber":"[0-9]*"' "$TMP_OUTPUT" | grep -o '[0-9]*' | tail -1)
rm "$TMP_OUTPUT"
ASC_BUILD=${ASC_BUILD:-$NEXT_BUILD}

echo "✅ Build $ASC_BUILD deployed. Check TestFlight on your phone."
