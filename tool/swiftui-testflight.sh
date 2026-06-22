#!/usr/bin/env bash
# Deploy Earshot SwiftUI to TestFlight.
# Usage: swiftui-testflight.sh [--notes "What to test"] [--public] [--both]
#
#   (no flag)   Upload to Internal Testing Group only
#   --public    Upload to Public Testers only
#   --both      Upload to both groups
#
# What this does:
#   1. Verifies the working tree is clean and in sync with remote
#   2. Bumps CURRENT_PROJECT_VERSION in project.yml and commits it
#   3. Regenerates the Xcode project via xcodegen
#   4. Archives and exports a release IPA
#   5. Uploads to the specified TestFlight group(s)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_ROOT="$REPO_ROOT/EarshotSwift"
PROJECT_YML="$SWIFT_ROOT/project.yml"
SCHEME="Earshot"
ARCHIVE_PATH="/tmp/Earshot.xcarchive"
EXPORT_PATH="/tmp/EarshotExport"
IPA_PATH="$EXPORT_PATH/Earshot.ipa"
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

# ── Safety checks ─────────────────────────────────────────────────────────────
BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [[ "$BRANCH" != "swift" ]]; then
  echo "❌ Must be on the swift branch to deploy. Currently on: $BRANCH"
  exit 1
fi

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
CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION' "$PROJECT_YML" \
  | head -1 | sed 's/.*CURRENT_PROJECT_VERSION: "//' | tr -d '"')
NEXT_BUILD=$((CURRENT_BUILD + 1))

sed -i '' "s/CURRENT_PROJECT_VERSION: \"$CURRENT_BUILD\"/CURRENT_PROJECT_VERSION: \"$NEXT_BUILD\"/" \
  "$PROJECT_YML"

git add "$PROJECT_YML"
git commit -m "chore: bump build number to $NEXT_BUILD for TestFlight"
git push origin "$BRANCH"

echo "▶ Build number: $NEXT_BUILD"

# ── Regenerate Xcode project ──────────────────────────────────────────────────
echo "▶ Regenerating Xcode project..."
cd "$SWIFT_ROOT"
xcodegen generate

# ── Archive ───────────────────────────────────────────────────────────────────
echo "▶ Archiving..."
xcodebuild archive \
  -project Earshot.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=iOS" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=72PH974742 \
  | grep -E "error:|warning:|Archive"

# ── Export IPA ────────────────────────────────────────────────────────────────
echo "▶ Exporting IPA..."
cat > /tmp/ExportOptions.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>teamID</key>
  <string>72PH974742</string>
  <key>uploadSymbols</key>
  <true/>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist /tmp/ExportOptions.plist \
  | grep -E "error:|Export"

# ── Upload ────────────────────────────────────────────────────────────────────
echo "▶ Uploading to TestFlight ($GROUP)..."
EXTRA_FLAGS=()
[[ -n "$NOTES" ]] && EXTRA_FLAGS+=(--test-notes "$NOTES" --locale en-US)
[[ "$SUBMIT_FOR_REVIEW" == true ]] && EXTRA_FLAGS+=(--submit --confirm)

asc publish testflight \
  --app "$ASC_APP_ID" \
  --ipa "$IPA_PATH" \
  --group "$GROUP" \
  --wait \
  --notify \
  "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"

echo "✅ Build $NEXT_BUILD deployed. Check TestFlight on your phone."
