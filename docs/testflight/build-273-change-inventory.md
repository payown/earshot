# Build 273 change inventory

Previous TestFlight build: 1.2.3 (272), App Store Connect build
`0d91a497-6ce4-42f9-b3c1-e673ed9c62b2`.

Build 273 addresses player responsiveness during root activation and isolates
Personal Audio playback-rate overrides per imported item.

## Changes

- Foreground root activation restores the last player item and publishes the
  interactive interface before expiration maintenance, Cloud projection,
  listening-history retention, and folder-run connection. Download recovery
  remains ahead of restoration so existing local media paths are repaired.
- Noncritical startup work is shared and canceled/awaited before local reset
  releases persistence. App Intent activation retains its complete startup
  sequence.
- Personal Audio rates are keyed by item ID in local preferences; they do not
  change global speed or podcast overrides. Another file falls back to the
  global default unless it has its own saved rate. The speed sheet and VoiceOver
  adjustable badge both apply the file scope; reset returns that file to the
  default. Deleting an item removes its saved rate.
- No SwiftData or CloudKit schema change; V13 remains current.

## Verification

- `PersonalAudioIntegrationTests` and `AdvancedPlaybackTests` passed, including
  per-file rate persistence, switching to a second file and podcast, reset,
  global-rate invariance, and observable VoiceOver rate revisions.
- `AppRuntimeTests` and `RootLaunchPreferencesTests` passed.
- `EarshotUITests.testCustomSpeedAndMiniPlayerLabel` passed, preserving the
  adjustable badge semantics and speed-sheet interaction for podcast playback.
- Startup code removes awaited noncritical tasks from the foreground readiness
  path. Physical-device VoiceOver timing is still needed to confirm the perceived
  improvement; simulator tests do not establish a device latency result.

## TestFlight

Chapter 94 / build 273 notes are saved in `build-273-notes.txt` and appended
verbatim to `docs/kashe.md`; the App Store Connect `en-US` notes were verified
to match. Build 273 (`f0853902-fa5b-4675-bdcf-713e089f449e`) was uploaded on
2026-09-29 and processed as `VALID`. It is available in both Internal Testing
Group and Public Testers. External beta review state is `APPROVED`, and
automatic tester notification is enabled.

## CI follow-up

The final revision's first GitHub Actions attempt (`36561284854`) ran 1,200
tests successfully and skipped three. Four failures were reported: three
test-host processes were killed by `SIGKILL`, followed by the test process
failing to bootstrap; there were no assertion failures among those failures.
The failed job was retried on the same source revision and passed the full test
job. The focused local suites listed above also passed.
