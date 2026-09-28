# Build 271 change inventory

Previous TestFlight build: 1.2.3 (270), App Store Connect build
`bc70458f-4372-44ee-b40a-3e8cefa84c80`.

Build 271 packages the approved Personal Audio V1 Phase 2 implementation on
top of the V12-to-V13 migration work. The migration keeps Personal Audio local
to the device and retains the existing Earshot Library, Queue, playback, and
subscription data. Michael installed build 270 over the existing TestFlight
installation for a real-data upgrade check and reports that things appear to
be going well.

Chapter 92 is stored verbatim in `docs/kashe.md` and
`build-271-notes.txt`. It calls out that Personal Audio is alpha and asks
testers to verify existing data before importing any files. Target groups:
Internal Testing Group and Public Testers.

App Store Connect processed build 1.2.3 (271) as VALID on 2026-09-27, build ID
`19a25cf8-348a-4d4d-ae2a-dde2659fbdaf`. The exact Chapter 92 text is attached
as the en-US What to Test notes. Both groups include the build; the internal
group receives all builds, and Public Testers has an explicit build assignment.
Apple approved the build for TestFlight beta review. App Store Connect reports
automatic tester notifications enabled.

The Release archive and exported IPA were signed with the Apple Distribution
certificate for team `72PH974742` and bundle ID `media.payown.earshot`.
App Store Connect TestFlight validation reported no issues.
