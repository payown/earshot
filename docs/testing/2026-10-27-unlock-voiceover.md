# Paused-player unlock investigation — October 27, 2026

Tracking: StartTesting `ec783e73-dcd7-4928-ae8d-d3f391b9e8fd`.
Source baseline: `be14c04e` (main, Earshot 1.2.5 build 279).
Branch: `codex/unlock-voiceover-279`.

## Current physical evidence

Michael paused playback with the full player open, locked his iPhone for five
seconds, unlocked, and immediately flicked with VoiceOver. VoiceOver was
unresponsive for approximately five seconds in all three attempts on build 279.
This is a user-observed duration, not a timed trace. The earlier September 25
non-reproduction on build 272 does not negate this current result.

## Measurement approach

The phone is reachable over the local network. Installed version 1.2.5 (279)
was verified with devicectl; device OS is 27.2 and host Xcode is 27.0 (27A266a).
Apple's current matrix lists Xcode 27.2 RC with the matching iOS SDK. Instruments
failed to produce a valid device trace during the previous investigation. This
pass uses an in-app diagnostic rather than claiming stack-profile evidence.

The temporary Release diagnostic is build 280, produced using a command-line
build-number override. No source version, signing configuration, capabilities,
entitlements, data schema, or accessibility semantics are changed.

`EARSHOT_UNLOCK_MEASURE=1` enables `UnlockResponsivenessProbe` for the launched
process. It records fixed-name events for application/scene/protected-data
lifecycle, VoiceOver focus and announcement completion, audio-route events,
full-player appearance, and durations for background persistence, badge loads,
search snapshot/diff/donation, cloud foreground retry, and feed refresh.

For up to 15 foreground captures, it requests a main-actor tick every 10 ms for
20 seconds, beginning at will-enter-foreground (or scene-active as fallback).
Encoding and atomic report writing run away from the main actor in one serialized
writer chain. The report is `Documents/earshot-unlock-279.json` in the app's data
container. It contains build, boolean VoiceOver/search consent state, timestamps,
durations and counts; no episode/show identifiers, spoken text, or URLs.

## Limitations

- Main-actor timer gaps include scheduler overhead and measure neither spoken
  response latency nor call stacks.
- Focus notifications can reveal focus-event timing, not the exact physical
  gesture timestamp. Correlate them with Michael's report.
- An async operation's elapsed span includes suspended time; a long span alone
  does not establish that it blocks the main actor.
- No capture covers work before the first foreground lifecycle callback.
- Diagnostic overhead and a direct development installation can affect behavior.
- The recorder stops taking new events after 30 minutes. Relaunching normally
  disables it; re-enable with the explicit environment variable.

## Device checks after installation

1. Leave the diagnostic process running. Open the full player and pause.
2. Lock five seconds, unlock, immediately flick with VoiceOver, then remain in
   Earshot at least 20 seconds. Report approximate delay and recovery.
3. Close the player and return to Library with that same episode still paused.
   Repeat lock/unlock/flick and the 20-second foreground interval as a control.
4. Retrieve the report and distinguish full-player and Library attempts using
   the appearance/disappearance events plus Michael's account.

## Installation and recorder verification

Release device build 280 succeeded under the required Xcode 27.0 toolchain.
The first two build attempts compiled successfully but failed signing because
Finder extended attributes were attached to the app under the Documents build
output. Rebuilding with `CONFIGURATION_BUILD_DIR` pointing to
`/private/tmp/earshot-unlock-280-products` succeeded. Automatic signing and the
required command-line team override were used; project signing is untouched.
`codesign --verify --deep --strict` passed.

Device installation and launch with `EARSHOT_UNLOCK_MEASURE=1` succeeded.
The installed-app query verified version 1.2.5, build 280. Retrieving the actual
report verified build 280, VoiceOver on, system search enabled, and lifecycle
events through scene-active/application-did-become-active. This is recorder
setup evidence, not an unlock reproduction or a fix.

No full regression suite was run for temporary observational instrumentation.
Existing baseline compiler warnings remain in unrelated files. No production
behavior fix, merge, App Store upload, or TestFlight distribution has occurred.
Awaiting Michael's paired full-player/Library unlock attempts and report retrieval.
