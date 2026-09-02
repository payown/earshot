# Next TestFlight change inventory

Status: Chapter 81, build 251 was uploaded to TestFlight and confirmed installed
by Michael on 2026-09-01. Build 251 superseded the uninstalled build 250
responsiveness candidate and is the current device-distributed integration
baseline.

The current shipped story is Chapter 81 for build 251. Future TestFlight uploads
must continue to follow the maintenance contract in `docs/kashe.md`:

- assign the chapter to the build that is actually uploaded;
- append the full chapter to `docs/kashe.md` in the same shipping change;
- update “Details established so far” for any new story facts;
- use that exact chapter as the TestFlight `--notes` payload;
- keep the complete chapter at or below 2,500 characters before upload.

## Changes represented by build 251

Chapter 81’s “What changed” and “What to test” sections account for every
applicable item below.

- Refresh reconciles corrected feed metadata for bounded recent and
  device-active episodes even when their GUID and publication date do not change.
- Corrected or invalid local audio is replaced without losing played,
  Inbox, queue, or listening-position state; superseded background completions
  cannot restore stale media.
- Episode Actions and Now Playing include Refresh episode audio, with
  one automatic retry for a failed local copy and a persistent accessible failure
  message when recovery does not succeed.
- Cold-launch maintenance, badge counts, refresh work, and compact Cloud
  projection no longer repeatedly occupy the main actor while VoiceOver is
  navigating Inbox and Settings.
- Queue folder grouping, group actions, reordering, and playback advancement use
  an episode's direct folder before its podcast's default folder.

## Shipping checklist

- [x] Reconcile this inventory with every change after build 249.
- [x] Choose the real final build number and the next chapter number.
- [x] Write one coherent Kashe chapter with plain-language “What changed” and
  “What to test” sections covering the inventory.
- [x] Append the chapter to `docs/kashe.md`; note any new durable story
  facts requiring an established-details update.
- [x] Save the exact same text as `docs/testflight/build-N-notes.txt`.
- [x] Verify the payload is at most 2,500 characters with `wc -m`.
- [x] Obtain Michael’s explicit TestFlight-upload approval.
- [x] Upload using the checked-in notes file and verify build 251 is available
  through TestFlight.
- [x] Confirm Michael installed and is using build 251.
