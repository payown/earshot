# September 23 due-task implementation plan

The first due feature to implement is the Library caught-up filter. Its existing
background unplayed counts provide the source of truth without traversing
Podcast.episodes or performing store reads during row rendering.

- Add an opt-in “Hide caught-up podcasts” toggle inside Library options.
- Default off, preserving the current Library and row speech.
- When enabled, display podcasts with at least one unplayed episode. Keep rows
  whose counts are still loading until a reliable count is available.
- Keep Library options available when every podcast is caught up so the user can
  turn the filter off. Show “All caught up” and explain how to show all podcasts.
- Persist the preference with existing app settings; refresh on existing
  unplayed-count invalidation events. Unfollowing and selection act on visible
  IDs. Do not unfollow, mark played, or delete anything as a filtering side effect.
- Test zero/unknown/positive counts, sorting, relaunch persistence, selection,
  and live count changes. Verify spoken controls and navigation on the phone.

AGENTS.md protects accessibility semantics. Michael explicitly approved the new toggle and empty-state wording in this
task on September 23; implementation and independent review are complete,
with physical-device acceptance pending. Existing labels,
rotor actions, traits, and focus behavior remain unchanged outside this feature.

Other due records:

- BBC transport: recheck published secure routes without changing ATS, trust, or
  download permission. A provider failure remains open if no secure route works.
- Home Screen badge: propose off by default, with downloaded-unheard count as the
  initial option. Count away from the main actor and update only on meaningful
  download/played-state changes. Request badge permission only on opting in.
- Retain completed Queue episodes: propose off by default. When enabled, keep
  completed membership but skip completed retained rows in auto-advance. Replay
  remains an explicit user action; existing download-retention policy stays
  independent. This needs end-of-queue and resume/replay tests before UI work.

These are review checkpoints, not release deadlines. No TestFlight distribution
is authorized. Independent verification must finish before a phone installation.
