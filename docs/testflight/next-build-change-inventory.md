# Next TestFlight change inventory

Status: source material only. This is not TestFlight copy and does not represent
an uploaded build.

The last shipped story is Chapter 70 for build 213. The next TestFlight upload
must follow the maintenance contract in `docs/kashe.md`:

- assign the chapter to the build that is actually uploaded;
- append the full chapter to `docs/kashe.md` in the same shipping change;
- update “Details established so far” for any new story facts;
- use that exact chapter as the TestFlight `--notes` payload;
- keep the complete chapter at or below 2,500 characters before upload.

## Significant changes since build 213

The next Kashe chapter’s “What changed” and “What to test” sections must account
for every applicable item below. They may group related behavior, but must not
fall back to generic “bug fixes and performance improvements” copy.

- Build 214: repeated and near-end seeks no longer bounce backward when a stale
  seek completion, playback tick, or private-iCloud handoff arrives late.
- Builds 215–220: stale played Inbox rows are repaired safely; downloaded audio
  is excluded from backups; store, projection, and media-transport evidence is
  bounded and telemetry-free; audio-session behavior has direct coverage; and a
  seeded UI smoke test now covers accessible Library, Inbox, and Queue launch.
- Build 221: in-place episode search within a podcast composes with heard state,
  sorting, selection, and Quick Actions.
- Build 222: in-progress rows show and, when enabled under Accessibility, speak
  both time remaining and total duration.
- Build 223: Downloads settings explains that new-episode auto-download count is
  per podcast, includes new Inbox and Queue episodes, and is not a storage cap.
- Build 224: transcripts export as timestamped, speaker-aware Markdown from the
  viewer or an episode action.
- Build 225: Inbox and Queue provide filter-scoped Download All with an exact
  confirmation and one final VoiceOver outcome summary.
- Build 226: a default-off Playback setting can dismiss the full player only
  after natural completion when no next episode will play.
- Build 227: Remove from Inbox dismisses an episode without marking it played and
  synchronizes that decision independently through private iCloud.
- Build 228: Quick Actions can be removed, restored, and reordered without drag,
  with stable VoiceOver focus and at least one action kept enabled.
- Build 229: a default-off Downloads setting sends an on-device notification
  after an episode finishes downloading and surfaces notification-permission
  recovery when needed.
- Build 230: Siri and Shortcuts provide Skip Forward and Skip Back actions. The
  built-in phrases use Earshot’s configured intervals; a Shortcut can supply a
  custom interval from 1 second through 10 minutes.

## Shipping checklist

- [ ] Reconcile this inventory with `CHANGELOG.md` and every merge after build
  230.
- [ ] Choose the real final build number and the next chapter number.
- [ ] Write one coherent Kashe chapter with plain-language “What changed” and
  “What to test” sections covering the inventory.
- [ ] Append the chapter and update established story details in `docs/kashe.md`.
- [ ] Save the exact same text as `docs/testflight/build-N-notes.txt`.
- [ ] Verify the payload with `wc -m`; tighten it to 2,500 characters or fewer.
- [ ] Obtain Michael’s explicit TestFlight-upload approval.
- [ ] Upload using the checked-in notes file and verify App Store Connect shows
  the same chapter.
