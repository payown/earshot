#!/usr/bin/env bash
# Deploy Earshot SwiftUI to TestFlight.
# Usage: swiftui-testflight.sh [--notes "What to test"] [--public] [--both] [--test]
#
#   (no flag)   Upload to Internal Testing Group only
#   --public    Upload to Public Testers only
#   --both      Upload to both groups
#   --test      Allow deploying from a NON-main branch (pre-merge test build).
#               Use this to TestFlight-test a feature/integration branch before
#               merging it to main. Bumps + commits the build number on THAT
#               branch, so use a throwaway/integration branch, and when you
#               later merge it to main the build-number bump comes along.
#
# Release builds run from `main`. Pre-merge test builds run from any branch
# with --test.
#
# What this does:
#   1. Verifies the working tree is clean and in sync with remote
#   2. Bumps CURRENT_PROJECT_VERSION in project.yml and commits it
#   3. Regenerates the Xcode project via xcodegen
#   4. Archives and exports a release IPA
#   5. Uploads to the specified TestFlight group(s)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The SwiftUI app now lives at the repo root (was EarshotSwift/ before the
# 2026-07-30 promotion). SWIFT_ROOT is kept as a name for the project dir.
SWIFT_ROOT="$REPO_ROOT"
PROJECT_YML="$SWIFT_ROOT/project.yml"
SCHEME="Earshot"
ARCHIVE_PATH="/tmp/Earshot.xcarchive"
EXPORT_PATH="/tmp/EarshotExport"
IPA_PATH="$EXPORT_PATH/Earshot.ipa"
ASC_APP_ID="6770760602"
GROUP="Internal Testing Group"
SUBMIT_FOR_REVIEW=false
NOTES=""
TEST_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes|-n) NOTES="$2"; shift 2 ;;
    --public)   GROUP="Public Testers"; SUBMIT_FOR_REVIEW=true; shift ;;
    --both)     GROUP="Internal Testing Group,Public Testers"; SUBMIT_FOR_REVIEW=true; shift ;;
    --test)     TEST_BUILD=true; shift ;;
    --resume)   RESUME=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Resume mode ───────────────────────────────────────────────────────────────
# --resume skips checks, bump, xcodegen, and archive, and goes straight to
# export + upload using the archive already at $ARCHIVE_PATH. Use it when a
# prior run archived successfully but died during export or upload, so a
# retry doesn't bump the build number a second time.
RESUME="${RESUME:-false}"
if [[ "$RESUME" == true ]]; then
  [ -d "$ARCHIVE_PATH" ] || { echo "❌ --resume: no archive at $ARCHIVE_PATH"; exit 1; }
  NEXT_BUILD=$(grep 'CURRENT_PROJECT_VERSION' "$PROJECT_YML" \
    | head -1 | sed 's/.*CURRENT_PROJECT_VERSION: "//' | tr -d '"')
  ARCHIVE_BUILD=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" \
    "$ARCHIVE_PATH/Info.plist" 2>/dev/null || echo "unknown")
  if [[ "$ARCHIVE_BUILD" != "$NEXT_BUILD" ]]; then
    echo "❌ --resume: archive is build $ARCHIVE_BUILD but project.yml says $NEXT_BUILD."
    exit 1
  fi
  echo "▶ Resuming export + upload for build $NEXT_BUILD"
fi

# ── Safety checks ─────────────────────────────────────────────────────────────
if [[ "$RESUME" != true ]]; then
BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [[ "$BRANCH" == "main" ]]; then
  : # production release from the trunk
elif [[ "$TEST_BUILD" == true ]]; then
  echo "⚠️  TEST build from non-main branch '$BRANCH' (pre-merge testing)."
  echo "    The build-number bump commits to '$BRANCH', not main."
else
  echo "❌ Releases deploy from 'main'. To cut a pre-merge test build from"
  echo "   this branch ('$BRANCH'), pass --test. Currently on: $BRANCH"
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
# Clear any stale archive/export from a previous run so a failed build can
# never let a stale IPA reach upload.
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
xcodebuild archive \
  -project Earshot.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=iOS" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=72PH974742 \
  | grep -E "error:|warning:|Archive" || true
# Gate on the real artifact, not grep's exit code: under `set -o pipefail` a
# grep with no match returns non-zero and would abort an otherwise-good build.
[ -d "$ARCHIVE_PATH" ] || { echo "❌ Archive failed (no .xcarchive produced)"; exit 1; }

fi  # end of non-resume (checks + bump + xcodegen + archive)
rm -rf "$EXPORT_PATH"

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
  | grep -E "error:|Export" || true

# Fallback: automatic signing can fail when the Xcode-managed cloud profile is
# stale (e.g. "iOS Team Store Provisioning Profile ... doesn't include signing
# certificate 'Apple Distribution'"). Retry with manual signing using the
# newest locally installed App Store profile for this bundle id, which we mint
# via `asc profiles create` and which does include the current cert.
if [ ! -f "$IPA_PATH" ]; then
  echo "⚠️  Automatic-signing export failed; retrying with manual signing..."
  PROFILE_NAME=$(
    for p in "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
      [ -f "$p" ] || continue
      security cms -D -i "$p" 2>/dev/null > /tmp/_earshot_prof.plist || continue
      APPID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" /tmp/_earshot_prof.plist 2>/dev/null || true)
      [ "$APPID" = "72PH974742.media.payown.earshot" ] || continue
      # App Store profiles have no device list; skip development/ad-hoc ones.
      /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" /tmp/_earshot_prof.plist >/dev/null 2>&1 && continue
      echo "$(stat -f %m "$p") $(/usr/libexec/PlistBuddy -c "Print :Name" /tmp/_earshot_prof.plist)"
    done | sort -rn | head -1 | cut -d' ' -f2-
  )
  if [ -z "$PROFILE_NAME" ]; then
    echo "❌ No installed App Store provisioning profile found for media.payown.earshot."
    exit 1
  fi
  echo "▶ Using profile: $PROFILE_NAME"
  cat > /tmp/ExportOptions.plist << PLIST
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
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>media.payown.earshot</key>
    <string>$PROFILE_NAME</string>
  </dict>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist /tmp/ExportOptions.plist \
    | grep -E "error:|Export" || true
fi

[ -f "$IPA_PATH" ] || { echo "❌ Export failed (no IPA produced)"; exit 1; }

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
