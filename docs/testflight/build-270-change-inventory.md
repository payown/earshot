# Build 270 change inventory

Previous TestFlight build: 1.2.3 (269), App Store Connect build
`bbb9e27f-6a90-422b-a324-0888c6ab803b`, main `3c7bec65`.

All application changes since that build are PR #989, merged as `c6ea4519`:
background download-path scanning with guarded, bounded repairs; cached initial
launch preferences; early tab selection; coalesced badge updates preserving
existing VoiceOver semantics. See the September 25 cold-launch timing report.

Michael tested signed Release 1.2.3 (270) on his phone and reported “much smoother,”
then authorized both TestFlight groups. This confirms the reported responsiveness
improvement; it does not imply every separate regression check was explicitly
confirmed. PR #989 passed CI; local tests had 2,400 passes, 33 skips, zero failures.

Chapter 91 is stored verbatim in docs/kashe.md and build-270-notes.txt, with testing
priorities first. This release changes the build number and documentation only
on top of the accepted production fix. Target groups: Internal Testing Group and
Public Testers. Distribution is verified against live App Store Connect state.
