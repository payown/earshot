# Per-podcast episode sorting

StartTesting item: `08d5c583-e618-4559-ab08-60be51336b57`.

Changing chronological order inside a Library podcast previously wrote the shared
`episode_sort_order` preference. All other podcasts consequently inherited the
change. The screen now loads and writes a canonical-feed-specific override and
uses it for initial loading, additional pages, search, filters, and refreshes.
Untouched podcasts retain the previous global preference as their fallback.

Overrides persist in device-local AppSetting rows. They do not sync between
devices. No schema, CloudKit contract, SettingsReset, signing configuration,
purchase UI, VoiceOver wording, or focus semantics changed. Sorting still does
not invoke playback or Queue mutation.

## Independent review

A second agent reviewed production and regression-test diffs independently and
approved both without functional blockers. Its comment correction was applied:
existing per-podcast filters are mirrored, whereas these new sort overrides are
intentionally device-local. The reviewer did not execute tests; results below
are from the implementation agent's simulator runs.

## Validation

- Xcode 27.0 (27A266a), iOS 26.5 simulator.
- Focused suites: 51 passed, one optional scale diagnostic skipped, zero failures.
- Full eligible unit suite: 2,369 passed, 33 skipped, zero failures. The two
  documented StoreKit suites were excluded.
- Signed Release 1.2.3 (267) build and strict code-signature verification passed.
- UI regression: one passed. Change Technically Working to oldest-first, verify
  Our Perspective remains newest-first, return and verify the saved first choice.
- Unit coverage includes independent feeds, reload through a fresh ModelContext,
  canonical URL aliases, legacy fallback, malformed stored values, local scope,
  search, filtering, and additional pages. UI asserts toggle state; actual row
  ordering is checked by data-source tests.

## Phone acceptance

1. Open a drama podcast from Library and choose oldest-to-newest.
2. Open another podcast, choose newest-to-oldest, then return to the drama.
3. Confirm each list retains its own order after navigating back, relaunching,
   refreshing, searching, changing the played filter, and loading more episodes.
4. Confirm VoiceOver announces the same controls/results, navigation remains
   responsive, and sorting does not start playback or reorder Queue contents.

Physical acceptance remains pending Michael's report. No TestFlight distribution
is part of this task.
