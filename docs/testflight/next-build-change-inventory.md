# Next TestFlight change inventory

As of 2026-10-09, version 1.2.5 build 275 (Chapter 96) is valid and assigned
to Internal Testing Group and Public Testers. Internal testing is active;
Apple's external beta review is still in progress. Build 273 is the last
confirmed externally available build. See `build-275-change-inventory.md`.

The next upload is version 1.2.5 build 276, Chapter 97. App Store Connect
reported 276 as the next available build number before preparation. Confirm
that again immediately before archiving.

## Changes since build 275

- #999: VoiceOver reads sanitized episode descriptions in Discover previews for
  unfollowed podcasts, respecting Off, Brief, and Full.
- #1000: BBC playback and background downloads use the verified HTTPS media
  selector; unverified routes retain the cleartext warning.
- #1001: The self-hosted simulator CI job restarts its dedicated simulator,
  retries failed cases once, and archives only the current failed result.
- #1002: Playback gains device-local compression strengths and a three-band
  equalizer, both off by default, with safe PCM processing and output limiting.
- Release follow-up: replace a previous dynamics-settings notification token
  when the player is rebound after an in-app reset.

Chapter 97 also repeats build 275's Queue tests because Public Testers may
receive build 276 before build 275 clears Apple beta review. Its exact text is
`docs/testflight/build-276-notes.txt` and the final chapter in `docs/kashe.md`.
No persistence schema, entitlement, or signing-setting change is planned.

## Release gates

- Independent code and release reviews, focused tests, and full CI pass.
- The archive reports version 1.2.5, build 276, and includes #999-#1002.
- The processed build is `VALID`; its en-US What to Test text matches the
  checked-in chapter.
- Verify both group memberships and each group's beta state separately. Public
  Testers availability requires Apple's external review. Tester notification
  configuration is distinct from confirmed individual delivery.
- Keep the relevant StartTesting features and issues in testing until physical
  playback, VoiceOver, and provider checks are reported.
