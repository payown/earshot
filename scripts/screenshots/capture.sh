#!/usr/bin/env bash
#
# App Store screenshot capture for Earshot (#643).
#
# Deterministic and repeatable: boots the app straight into each target screen
# via DEBUG-only launch arguments (see Earshot/App/Screenshots/), against an
# in-memory store seeded from Michael's real Pinecast feeds. Re-running produces
# the same six screens every time.
#
# WHAT IS REAL vs SYNTHESIZED: every podcast, episode, title, artwork, and audio
# URL is real (pulled from the live feeds). Per-episode state (played /
# downloaded / queued / in-progress) is set by the fixture to look lived-in. The
# ONLY fabricated content is the chapter list on the "Now Playing" episode
# (Technically Working #170), whose timestamps are authored in the fixture so the
# shipped chapter parser produces a list — the chapter feature itself is real.
# Full provenance: Earshot/App/Screenshots/ScreenshotFixtures.swift.
#
# Usage:
#   scripts/screenshots/capture.sh [OUTPUT_DIR]
#
# Env:
#   EARSHOT_SCREENSHOT_SIM   Simulator UDID to use. Default: a 6.9" iPhone 17 Pro
#                            Max. MUST NOT be the CI-reserved UDID
#                            (23F12FE1-0D77-4B42-B766-ADD9F27A2153, "CI-iPhone-17").
#   EARSHOT_APP_PATH         Pre-built Earshot.app to install instead of building.
#
set -euo pipefail

SCHEME="Earshot"
BUNDLE_ID="media.payown.earshot"
# Default: an iPhone 17 Pro Max (6.9", the current App Store reference class).
# Deliberately NOT the CI-reserved simulator.
SIM_UDID="${EARSHOT_SCREENSHOT_SIM:-38284C7C-E08A-40E5-AACA-C654C8A48E2A}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"   # repo root (Earshot.xcodeproj lives here)
OUT_DIR="${1:-$SCRIPT_DIR/output}"

# Order matters: the first screen that shows artwork warms the shared artwork
# disk cache for the rest. A dedicated warm-up launch (below) covers it anyway.
SCREENS=(inbox queue library episodeList nowPlaying settings)

mkdir -p "$OUT_DIR"

# --- 1. Build (unless a prebuilt app was provided) -------------------------
if [[ -n "${EARSHOT_APP_PATH:-}" ]]; then
  APP="$EARSHOT_APP_PATH"
  echo "==> Using prebuilt app: $APP"
else
  echo "==> Building Earshot (Debug) for the simulator"
  DERIVED="$(mktemp -d)"
  xcodebuild \
    -project "$PROJECT_DIR/Earshot.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "id=$SIM_UDID" \
    -derivedDataPath "$DERIVED" \
    build | tail -6
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/Earshot.app"
fi
[[ -d "$APP" ]] || { echo "!! App not found at $APP" >&2; exit 1; }

# --- 2. Boot the simulator with a clean status bar -------------------------
echo "==> Booting simulator $SIM_UDID"
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$SIM_UDID"
xcrun simctl bootstatus "$SIM_UDID" >/dev/null 2>&1 || true
# The classic clean App Store status bar: 9:41, full battery/signal.
xcrun simctl status_bar "$SIM_UDID" override \
  --time "9:41" \
  --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 \
  --dataNetwork wifi --wifiMode active --wifiBars 3

# --- 3. Install ------------------------------------------------------------
echo "==> Installing app"
xcrun simctl install "$SIM_UDID" "$APP"

launch_screen() {
  local screen="$1"
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" \
    -uiTestScreenshotSeed -screenshotScreen "$screen" >/dev/null
}

# --- 4. Warm the artwork disk cache so no shot renders a placeholder --------
echo "==> Warming artwork cache"
launch_screen library
sleep 8

# --- 5. Capture each screen ------------------------------------------------
for screen in "${SCREENS[@]}"; do
  echo "==> Capturing $screen"
  launch_screen "$screen"
  # First-launch seed + artwork (from cache) + async show-notes chapter parse.
  sleep 6
  xcrun simctl io "$SIM_UDID" screenshot "$OUT_DIR/${screen}.png"
done

xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "==> Done. Six screenshots written to:"
echo "    $OUT_DIR"
ls -1 "$OUT_DIR"
