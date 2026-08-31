# Next TestFlight change inventory

Status: Chapter 79, build 249 shipped to the Internal Testing Group and Public
Testers on 2026-08-31. Its exact copy is in `build-249-notes.txt`.

The last shipped story is Chapter 78 for build 248. This TestFlight upload
follows the maintenance contract in `docs/kashe.md`:

- assign the chapter to the build that is actually uploaded;
- append the full chapter to `docs/kashe.md` in the same shipping change;
- update “Details established so far” for any new story facts;
- use that exact chapter as the TestFlight `--notes` payload;
- keep the complete chapter at or below 2,500 characters before upload.

## Significant changes since build 248

The next Kashe chapter’s “What changed” and “What to test” sections must account
for every applicable item below. They may group related behavior, but must not
fall back to generic “bug fixes and performance improvements” copy.

- Build 249: Discovery previews expose the available feed with episode search,
  newest/oldest sorting, immediate playback, and queue actions without requiring
  a follow or download.
- Build 249: Catalog podcasts promote into followed Library podcasts without
  losing queue, played, or listening-position state; streaming OPML progress is
  preserved.
- Build 249: Remote queue reconciliation no longer carries SwiftData relationship
  objects across an actor suspension. The application context applies a plain
  queue plan atomically, preventing the build-248 completion-versus-sync crash
  and episode resurrection.

## Shipping checklist

- [x] Reconcile this inventory with every change after build 241.
- [x] Choose the real final build number and the next chapter number.
- [x] Write one coherent Kashe chapter with plain-language “What changed” and
  “What to test” sections covering the inventory.
- [x] Append the chapter to `docs/kashe.md`; note any new durable story
  facts requiring an established-details update.
- [x] Save the exact same text as `docs/testflight/build-N-notes.txt`.
- [x] Verify the payload is at most 2,500 characters with `wc -m`.
- [x] Obtain Michael’s explicit TestFlight-upload approval.
- [x] Upload using the checked-in notes file and verify App Store Connect shows
  the same chapter.
