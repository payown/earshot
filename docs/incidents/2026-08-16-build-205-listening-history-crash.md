# Build 205 listening-history crash

## Impact

Three TestFlight crash submissions from the same public-link tester showed the
same deterministic failure on an iPhone18,1 running iOS 26.6:

- `ACi1Pd1lApbst2oge3QXpIg`, 2026-08-15 at 11:53 PM Pacific
- `AFDpGQNt9m53SfzLNsGjxic`, 2026-08-16 at 5:26 AM Pacific
- `AIaf0nunoAKbfl4iS1XS1c4`, 2026-08-16 at 6:38 PM Pacific

The first report mentioned VoiceOver Read All. The second occurred after the
app had moved to the background. The third said that opening the app caused a
crash. Read All and VoiceOver were not the cause; the reports exposed different
timings for the same launch-time iCloud reconciliation failure. Although the
third submission arrived after newer builds were available, its crash metadata
explicitly identifies Earshot 1.1.0 (205).

## Signature and cause

All three symbolicated reports ended in the same uncatchable `EXC_BREAKPOINT` /
`SIGTRAP`:

```text
_InvalidFutureBackingData.getValue
Podcast.feedURL.getter
CloudProjectionCoordinator.applyRemoteListeningHistory
CloudProjectionCoordinator.reconcile
```

A listening-history row could retain a relationship foreign key after an older
unsubscribe or Cloud reconciliation cascade removed its Podcast or Episode.
SwiftData represented the missing destination as a future fault. Reading a
stored property from that fault traps inside SwiftData instead of throwing an
error Earshot can catch. Build 205 also performed narrow Podcast fetches in the
application context before history reconciliation, increasing the chance that
relationship traversal would encounter incomplete backing data.

## Build 206 remediation

Build 206 establishes two defenses:

1. Before opening a settled V10 store, an idempotent SQLite transaction repairs
   invalid history foreign keys. A live Episode can restore its Podcast; a
   missing Episode becomes podcast-level history; only a history row with no
   surviving Podcast identity is removed.
2. Cloud history reconciliation snapshots relationship identifiers and resolves
   Podcast and Episode scalar identity in independent SwiftData contexts. It no
   longer reads `feedURL` or `guid` from a model reached through a history-row
   relationship in the application context.

No CloudKit schema or accessibility semantics changed.

## Regression evidence

The regression suite creates real V10 SQLite stores, deliberately writes the
two dangling foreign-key shapes, then reopens and reconciles each store twice.
The Podcast fault is removed without a projection duplicate or crash. The
Episode fault preserves its history duration, speed, date, and Podcast identity
while safely dropping only the missing Episode association.

The focused dangling-history regression tests passed again on current `main`
(which contains the build 206 repair and subsequent build 209 changes) on
2026-08-16. The late third report is therefore evidence from the already
superseded build 205, not evidence that the repair failed. Testers must update
to the current build before evaluating this fix.

Every crash notification must still be submitted through TestFlight with the
approximate time, action, and installed build number. Repeated reports are
valuable because they prove whether failures share a signature rather than
being noise.
