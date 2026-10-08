# Next TestFlight change inventory

Current public TestFlight build: Chapter 94, build 273 (version 1.2.3),
uploaded on 2026-09-29 and processed as `VALID`. It remains available to
Internal Testing Group and Public Testers; external beta review is approved.
See `build-273-change-inventory.md` for its exact change and verification
record. Michael confirmed the on-phone acceptance test passed.

Chapter 95, build 274 (version 1.2.4), was uploaded on 2026-10-05 and
processed as `VALID` for App Store review. Its exact notes are in
`build-274-notes.txt` and `docs/kashe.md`. Internal Testing Group has access
through its all-builds setting. Build 274 is not assigned to Public Testers,
so their approved 1.2.3 build remains available.

Chapter 96, build 275 (version 1.2.5), is processed as valid and assigned to
both groups. Internal access is active; Public Testers access awaits Apple beta
review. See `build-275-change-inventory.md` for the exact status and checks.

Future TestFlight uploads must continue to follow the maintenance contract in
`docs/kashe.md`:

- assign the chapter to the build that is actually uploaded;
- append the full chapter to `docs/kashe.md` in the same shipping change;
- update “Details established so far” for any new story facts;
- use that exact chapter as the TestFlight `--notes` payload;
- keep the complete chapter at or below 2,500 characters before upload.

## Changes represented by build 273

Chapter 94's “What to try first” and “Kashe's story” sections account for every
applicable item below. No database migration was added.

- Root activation defers noncritical startup maintenance until after the
  interface is interactive.
- Personal Audio playback speed is remembered per imported file without
  changing the app or podcast default.
- No SwiftData or CloudKit schema change was added.

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
- [x] Upload using the checked-in notes file and verify build 273 is available
  to both tester groups.
- [x] Confirm on-phone acceptance with Michael before advancing the release.
