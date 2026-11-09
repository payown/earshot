# Private TestFlight build 315 — November 9, 2026

Earshot **1.2.6 (315)** was archived from clean protected `main` at
`ace58c3289bb6125f69e777a1ff621507f51f4f5`, after PRs #1052–#1060 merged.
Required PR CI for #1060 (run 42562487574) and post-merge `main` CI
(run 42564921798) each completed 2,749 iPhone unit and 41 UI tests with
zero failures; they reported 34 unit and 8 UI scheme skips. Four narrow CLI
exclusions remain: two StoreKit simulator suites and two methods reproduced
on unchanged build 313. The exact evidence is in
[the 314 quality report](../watchos-playback-quality-314.md).

The Release archive `/tmp/EarshotWatch315Signed.xcarchive` and App Store
export `/tmp/EarshotWatch315Export/Earshot.ipa` succeeded with command-line
signing overrides and the existing three App Store profiles. The IPA's phone,
independent Watch app, and Watch widget all report **1.2.6 (315)** and pass
strict signature verification. The distributed Watch has background audio,
the approved Watch App Group, the existing CloudKit container, and
`get-task-allow=false`. The IPA SHA-256 is
`103e0d1799bffa430a986dc2ab36698d617fe8761a5ec1ada4e2a59f2f04e087`.
No project signing settings or entitlements were edited.

App Store Connect build `21b17812-95f1-4dfd-83fa-bfbe90584cf8` is
`VALID`, upload `COMPLETE`, and internally `IN_BETA_TESTING`. The existing
**Internal Testing Group** has automatic all-build access; it contains seven
testers, and Michael explicitly authorized this private group for 315. The
complete build-group lookup returned only that internal group. External state
is `READY_FOR_BETA_SUBMISSION`; build 315 has not been submitted to or assigned
to Public Testers, and no App Store release was made. No separate tester
notification was requested, so individual notification delivery is unverified.

Live en-US What to Test matches [Chapter 120](../kashe.md) and
`build-315-notes.txt` exactly apart from App Store Connect removing the file's
final newline. Michael approved that chapter and those notes before upload.

Physical acceptance remains open: update iPhone and Watch in place, repeat
Watch opens with iPhone foreground/background, compare handoff speech and
position at 1x and 1.5x, try VoiceOver Magic Tap on Watch Home, Now Playing,
and iPhone Control, test direct/offline Watch playback and CloudKit Queue
reconciliation, and check iPad/Duo navigation and focus. Immediate paired
Queue snapshots remain disabled after the earlier physical iPhone crash.
The iPadOS 26.0 Search simulator crash and two baseline-excluded CloudKit/reset
tests also remain release risks. This internal build is a device-test candidate,
not approval for public beta or version 1.3.
