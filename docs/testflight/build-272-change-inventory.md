# Build 272 change inventory

Previous TestFlight build: 1.2.3 (271), App Store Connect build
`19a25cf8-348a-4d4d-ae2a-dde2659fbdaf`.

Build 272 is a Personal Audio V1 closeout build. It improves item-row VoiceOver
actions, spoken details, played and now-playing indicators, and item focus. It
keeps the dedicated Personal Audio destination and the existing podcast row
actions.

There is no additional database schema or migration change from build 271 to
272. Build 271 introduced schema V13 and the device-local `PersonalAudioItem`;
272 retains V13 unchanged. No new Personal Audio fields or mirrored CloudKit
models are added.

Chapter 93 is stored verbatim in `docs/kashe.md` and
`build-272-notes.txt`. It asks testers to verify their existing library and
Queue before testing the Personal Audio rotor and import/playback workflows.
Target groups: Internal Testing Group and Public Testers.

App Store Connect processed build 1.2.3 (272) as VALID on 2026-09-28, build ID
`0d91a497-6ce4-42f9-b3c1-e673ed9c62b2`. The en-US What to Test localization
matches Chapter 93. Beta App Review approved it. Both group states are
`IN_BETA_TESTING`: Internal Testing Group receives all builds, and Public
Testers has an explicit assignment. Automatic tester notifications are enabled.

The Release archive and exported IPA use the Apple Distribution certificate
for team `72PH974742` and bundle ID `media.payown.earshot`. App Store Connect
build processing reported no issues.

Closeout verification: 109 selected regression tests passed; the Personal Audio
Library UI test passed; both Library podcast snapshot tests passed. Physical
checks for real-file import, Lock Screen playback, VoiceOver rotor interaction,
and device backup remain tester verification.
