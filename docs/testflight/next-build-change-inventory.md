# Next TestFlight change inventory

Status: Chapter 80, build 250 is prepared but not uploaded. Its proposed exact
copy is in `build-250-notes.txt`. Chapter 79, build 249 remains the newest build
shipped to the Internal Testing Group and Public Testers on 2026-08-31.

The last shipped story is Chapter 79 for build 249. The prepared TestFlight
upload must follow the maintenance contract in `docs/kashe.md`:

- assign the chapter to the build that is actually uploaded;
- append the full chapter to `docs/kashe.md` in the same shipping change;
- update “Details established so far” for any new story facts;
- use that exact chapter as the TestFlight `--notes` payload;
- keep the complete chapter at or below 2,500 characters before upload.

## Significant changes since build 249

The next Kashe chapter’s “What changed” and “What to test” sections must account
for every applicable item below. They may group related behavior, but must not
fall back to generic “bug fixes and performance improvements” copy.

- Build 250: Refresh reconciles corrected feed metadata for bounded recent and
  device-active episodes even when their GUID and publication date do not change.
- Build 250: Corrected or invalid local audio is replaced without losing played,
  Inbox, queue, or listening-position state; superseded background completions
  cannot restore stale media.
- Build 250: Episode Actions and Now Playing include Refresh episode audio, with
  one automatic retry for a failed local copy and a persistent accessible failure
  message when recovery does not succeed.

## Shipping checklist

- [x] Reconcile this inventory with every change after build 249.
- [x] Choose the real final build number and the next chapter number.
- [x] Write one coherent Kashe chapter with plain-language “What changed” and
  “What to test” sections covering the inventory.
- [x] Append the chapter to `docs/kashe.md`; note any new durable story
  facts requiring an established-details update.
- [x] Save the exact same text as `docs/testflight/build-N-notes.txt`.
- [x] Verify the payload is at most 2,500 characters with `wc -m`.
- [ ] Obtain Michael’s explicit TestFlight-upload approval.
- [ ] Upload using the checked-in notes file and verify App Store Connect shows
  the same chapter.
