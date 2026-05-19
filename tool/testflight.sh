#!/usr/bin/env bash
# Deploy to TestFlight.
# Usage: testflight [--notes "What to test"]
#
# What this does:
#   1. Verifies you're on main and fully pushed
#   2. Bumps the build number in pubspec.yaml and commits it
#   3. Builds a release IPA
#   4. Uploads to the Internal Testing Group on TestFlight
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

# ── Safety checks ────────────────────────────────────────────────────────────
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
  echo "❌ You're on branch '$BRANCH'. Merge to main before deploying."
  exit 1
fi

git fetch origin main --quiet
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [[ "$LOCAL" != "$REMOTE" ]]; then
  echo "❌ Local main is out of sync with origin. Push or pull first."
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "❌ Uncommitted changes. Commit or stash before deploying."
  exit 1
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
git push origin main

echo "▶ Version: $NEW_VERSION"

# ── Build ─────────────────────────────────────────────────────────────────────
echo "▶ Building release IPA..."
flutter build ipa --release

# ── Upload ────────────────────────────────────────────────────────────────────
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

echo "✅ Build $NEXT_BUILD deployed. Check TestFlight on your phone."
