# Build 205 listening-history crash

## Impact

Two TestFlight crash submissions from the same public-link tester showed the
same deterministic failure on an iPhone18,1 running iOS 26.6:

- `ACi1Pd1lApbst2oge3QXpIg`, 2026-08-15 at 11:53 PM Pacific
- `AFDpGQNt9m53SfzLNsGjxic`, 2026-08-16 at 5:26 AM Pacific

The first report mentioned VoiceOver Read All. The second occurred after the
app had moved to the background. Read All and VoiceOver were not the cause;
they exposed different timings for the same launch-time iCloud reconciliation
failure.

## Signature and cause

Both symbolicated reports ended in an uncatchable `EXC_BREAKPOINT` / `SIGTRAP`:

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

Build 206 must not be promoted beyond TestFlight until testers exercise launch,
background return, listening-history creation, iCloud reconciliation, and
VoiceOver Read All. Every crash notification must be submitted through
TestFlight with the approximate time and action; repeated reports are valuable
because they prove whether failures share a signature rather than being noise.
