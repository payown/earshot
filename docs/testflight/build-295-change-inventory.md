# Build 295 TestFlight handoff

Version 1.2.5, build 295, Chapter 103. App Store Connect build
`ce102ea7-c0e4-4c22-8be8-cd9c210acf3f` processed as `VALID` on 2026-10-31.
PRs: #1030 (Quick Actions VoiceOver fix), #1031 (chapter and release notes),
and #1032 (build number and protected-main release support).

## Changes

- Player transport Quick Actions now expose one VoiceOver Remove action per
  enabled row while retaining the move actions. The native swipe Remove
  control is hidden from the VoiceOver action list to avoid a duplicate.
- Build 295 asks the tester to verify that a transport action exposes one
  Remove action and the available move actions. The exact TestFlight notes are
  `docs/testflight/build-295-notes.txt` and match Chapter 103 in `docs/kashe.md`.
- The release script now accepts `--no-bump` on `main` when a protected-branch
  PR has already prepared the build number.

## Verification

- The user confirmed the duplicate Remove issue passed on development build 294.
- PR #1030's required full CI check passed. PR #1031's full CI check passed in
  14m19s. PR #1032's final full CI check passed in 26m38s after Xcode collected
  simulator diagnostics; the test step ultimately succeeded.
- `bash -n tool/swiftui-testflight.sh`, `git diff --check`, and the Chapter 103
  versus TestFlight notes equality check passed.
- The release archive completed and App Store Connect accepted the IPA.

## Distribution

- Build 295 is `VALID` and in `IN_BETA_TESTING` for both groups.
- Internal Testing Group has all-build access. Public Testers has explicit
  build 295 membership, and Apple's beta app review is `APPROVED`.
- `autoNotifyEnabled` is true. This confirms automatic notification is
  configured; individual notification delivery was not independently verified.
- The initial group assignment call returned an Apple server error. Retrying
  the Public Testers assignment by build ID succeeded, and both group
  memberships and beta states were read back from App Store Connect.
