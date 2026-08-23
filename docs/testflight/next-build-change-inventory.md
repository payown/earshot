# Next TestFlight change inventory

Status: collecting changes after Chapter 71, build 232, which shipped to the
Internal Testing Group and Public Testers on 2026-08-23. The exact build 232
copy is in `build-232-notes.txt`.

The last shipped story is Chapter 71 for build 232. The next TestFlight upload
must follow the maintenance contract in `docs/kashe.md`:

- assign the chapter to the build that is actually uploaded;
- append the full chapter to `docs/kashe.md` in the same shipping change;
- update “Details established so far” for any new story facts;
- use that exact chapter as the TestFlight `--notes` payload;
- keep the complete chapter at or below 2,500 characters before upload.

## Significant changes since build 232

The next Kashe chapter’s “What changed” and “What to test” sections must account
for every applicable item below. They may group related behavior, but must not
fall back to generic “bug fixes and performance improvements” copy.

- Build 233: Podcast Quick Actions can open the existing download-count,
  queue-age-limit, and playback-speed editors directly, moving VoiceOver focus
  to the native adjustable control without adding duplicate settings.
- Build 234: Queue options can save the current episode order as a reusable
  lineup and apply it later. Applying a lineup preserves other queued episodes,
  skips unavailable or already-played entries, and announces exact applied and
  skipped counts.
- Build 235: Playback adds a VoiceOver-first Volume Boost control with Off,
  Low, Medium, and High levels. It is available globally and per podcast, keeps
  the system volume unchanged, and applies live during playback.
- Build 236: Silence trimming now performs real-time silence compaction instead
  of exposing an inactive setting. It can be enabled globally or overridden per
  podcast and applies live without changing an episode's saved position.
- Build 237: the misleading Voice Enhance switch has been removed. It selected
  a spoken-audio session mode and mono output but did not enhance speech. Normal
  stereo playback and the stable time-stretch algorithm remain in use.
- Build 238: Playback's Settings-row VoiceOver hint now says Volume Boost
  instead of advertising the removed Voice Enhance control.
- Maintenance since build 232 also expands the seeded navigation smoke test to
  adapt to iPad layouts and adds direct coverage for the audio-processing path.

## Shipping checklist

- [x] Reconcile this inventory with `CHANGELOG.md` and every change after build
  232.
- [ ] Choose the real final build number and the next chapter number.
- [ ] Write one coherent Kashe chapter with plain-language “What changed” and
  “What to test” sections covering the inventory.
- [ ] Append the chapter to `docs/kashe.md`; note any new durable story
  facts requiring an established-details update.
- [ ] Save the exact same text as `docs/testflight/build-N-notes.txt`.
- [ ] Verify the payload is at most 2,500 characters with `wc -m`.
- [ ] Obtain Michael’s explicit TestFlight-upload approval.
- [ ] Upload using the checked-in notes file and verify App Store Connect shows
  the same chapter.
