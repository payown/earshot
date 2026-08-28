# Next TestFlight change inventory

Status: build 242 is prepared for the Internal Testing Group and Public Testers.
Its exact Chapter 75 copy is in `build-242-notes.txt`.

The last shipped story is Chapter 74 for build 241. The next TestFlight upload
must follow the maintenance contract in `docs/kashe.md`:

- assign the chapter to the build that is actually uploaded;
- append the full chapter to `docs/kashe.md` in the same shipping change;
- update “Details established so far” for any new story facts;
- use that exact chapter as the TestFlight `--notes` payload;
- keep the complete chapter at or below 2,500 characters before upload.

## Significant changes since build 241

The next Kashe chapter’s “What changed” and “What to test” sections must account
for every applicable item below. They may group related behavior, but must not
fall back to generic “bug fixes and performance improvements” copy.

- Build 242: Player entry points now verify that a retained episode still exists
  before using it, and identity repair unloads duplicate episodes before their
  SwiftData rows are deleted.
- Build 242: Compact Cloud projection reconciliation now owns background
  SwiftData contexts, keeping large sync/import work off the main actor without
  changing the stored schema, synced fields, analytics, or privacy behavior.

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
- [ ] Upload using the checked-in notes file and verify App Store Connect shows
  the same chapter.
