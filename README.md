# Earshot (native Swift) — accessibility-core slice

A native SwiftUI rewrite of Earshot, on the `swift` branch. This is the first
runnable slice, not the full app. It exists so you can feel native iOS
accessibility (especially the VoiceOver Actions rotor) on a real device and
compare it head-to-head with the Flutter build.

## What works in this slice

- Subscribe to a podcast by RSS URL (two sample feeds provided), persisted with
  SwiftData.
- Accessible episode list per podcast.
- **Quick Actions + VoiceOver rotor:** each episode row exposes Play now, Mark
  as played/unplayed, Open show notes, and Share as VoiceOver custom actions, in
  the order you set. The first action is the default double-tap.
- **Reorder in the Actions tab** and the rotor updates **immediately** — no
  startup seeding, no relaunch. (This is the native payoff over the Flutter
  build, where the rotor order is locked per launch.)
- Basic AVFoundation playback with a Now Playing bar (play/pause).

## Not in this slice yet

Downloads, queue, inbox, OPML, share extension, search, bookmarks, sleep timer,
podcast/player screens, settings beyond Quick Actions. These come next,
feature-by-feature, toward parity with the Flutter app.

## Requirements

- Xcode 16+ (built with Xcode 26.5), iOS 17+ device or simulator.

## Run it

```bash
# The Xcode project is committed at the repo root, just open it:
open Earshot.xcodeproj
# (If you change project.yml, regenerate with: xcodegen generate)
```

In Xcode: pick a simulator or your device, press Run. Bundle id is
`media.payown.earshot.swift`, so it installs alongside the Flutter Earshot.

## What to test (VoiceOver)

1. Add a sample feed (Podcasts tab → +).
2. Open a podcast, turn on VoiceOver, focus an episode.
3. Open the Actions rotor (rotate to "Actions", swipe up/down). Confirm the
   actions are in the configured order; double-tap the row to run the default.
4. Go to the Actions tab, tap Edit, drag to reorder, tap Done.
5. Back on an episode, check the rotor order changed **without relaunching**.
