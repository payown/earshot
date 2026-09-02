# Build 251 TestFlight status

Date: 2026-09-01 (US/Pacific)

## Distributed build

- Version: Earshot 1.2.0 (251)
- Source branch: `codex/voiceover-responsive-build-250`
- Source commit: `6a6c6c5` (`chore: regenerate project for build 251`)
- TestFlight status: uploaded and available
- Device status: Michael confirmed that build 251 is installed and in active use

Build 251 supersedes the uninstalled build 250 responsiveness candidate. Its
TestFlight chapter is preserved verbatim in
`docs/testflight/build-251-notes.txt` and in Chapter 81 of `docs/kashe.md`.

## Evidence boundary

This record confirms distribution and installation. It does not replace the
missing Instruments measurements documented in
`2026-08-31-build-250-voiceover-responsiveness.md`. Xcode 26.6 could not trace
the iOS 27 device, and the later Xcode 27 beta attempt did not establish a stable
control channel. No wall-time, longest-main-thread-interval, peak-memory, or
right-flick-latency values should be inferred from TestFlight availability.

The accepted behavioral contract remains unchanged spoken labels, values,
traits, Actions rotor order, default activation, focus restoration, and
announcements.
