# Next TestFlight change inventory

Status: collecting changes after Chapter 72, build 239, which shipped to the
Internal Testing Group and Public Testers on 2026-08-23. The exact build 239
copy is in `build-239-notes.txt`.

The last shipped story is Chapter 72 for build 239. The next TestFlight upload
must follow the maintenance contract in `docs/kashe.md`:

- assign the chapter to the build that is actually uploaded;
- append the full chapter to `docs/kashe.md` in the same shipping change;
- update “Details established so far” for any new story facts;
- use that exact chapter as the TestFlight `--notes` payload;
- keep the complete chapter at or below 2,500 characters before upload.

## Significant changes since build 239

The next Kashe chapter’s “What changed” and “What to test” sections must account
for every applicable item below. They may group related behavior, but must not
fall back to generic “bug fixes and performance improvements” copy.

- Build 240: Podcast feeds offering several transcript representations now
  prefer structured JSON, WebVTT, or SRT over HTML. Existing HTML transcript
  URLs also convert semantic cue-time elements into structured metadata, so all
  three styles work in the live view and both export paths without deleting
  clock times spoken as part of the episode.

## Shipping checklist

- [ ] Reconcile this inventory with `CHANGELOG.md` and every change after build
  239.
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
