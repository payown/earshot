# TestFlight build 296 inventory

Version 1.2.5, build 296, Chapter 104. App Store Connect build
`27d24679-67b5-4a9a-b468-cdac7859eb05` processed as `VALID` on 2026-10-31.

## Changes

- VoiceOver reorder actions for the horizontal Player transport row now say
  “Move left,” “Move right,” “Move to far left,” and “Move to far right.”
  Other Quick Actions lists retain their vertical Move up/down wording.
- Reorder confirmations now speak the matching direction and resulting
  position. The underlying order and move offsets are unchanged.
- The TestFlight notes credit Robin and other Earshot users for feedback that
  shaped the transport controls. The full Chapter 104 is recorded in
  `docs/kashe.md`; the checked-in notes are
  `docs/testflight/build-296-notes.txt`.

## Verification

- Focused iOS Simulator tests passed: 17 tests across
  `QuickActionMoveLogicTests` and `QuickActionSettingsRotorActionTests`.
- The Release archive and App Store export succeeded with Xcode 27.0.
- The uploaded build is `VALID`. Its en-US TestFlight notes match Chapter 104.
- Internal Testing Group has all-build access, so build 296 was available to
  that group without a separate build assignment. Its internal beta state is
  `IN_BETA_TESTING`; external beta state is `READY_FOR_BETA_SUBMISSION`.
- App Store Connect reports automatic notifications enabled. The upload did
  not require a separate group assignment; individual notification delivery
  was not confirmed.

## Distribution

- Build 296 was uploaded to the Internal Testing Group. It was not submitted
  for external beta review or assigned to Public Testers.
- Branch: `testflight/transport-horizontal-296`.
