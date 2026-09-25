# Queue rendering performance

StartTesting feature: `314140b5-bbe8-48f7-b6e6-21c3eef43516`.

## Finding and change

In QueueScreen.flatList, every realized row read the computed `episodes.count`.
That property traverses all queried QueueItems with compactMap to resolve their
episode relationships. With N queue items and R row evaluations, this adds N × R
relationship reads and R temporary arrays just to obtain the same total.

The flat list now captures the current episode array and its count once, before
constructing the filtered indexed rows. Row closures capture the integer total.
This removes the per-row full-queue traversal; the snapshot is local to each
render and is not retained in State or a cache. Query changes rebuild it.

Original numbering is preserved: enumerate before filtering, and report the
unfiltered episode total (excluding orphan QueueItems), just as before. Row
identity, row implementation, labels, values, hints, rotor actions, focus, drag
handlers and grouped rendering are unchanged. No schema or synchronization edits.

This is a code-level work reduction, not a measured phone latency improvement.
Lazy List realization means R is not necessarily the entire queue length.
Grouped rendering remains a separate profiling candidate.

## Validation

Xcode 27.0 / iOS 26.5 simulator: 123 focused tests passed across QueueLogicTests,
QueueRepositoryTests, EpisodeSearchFilterTests and SearchResultPositionTests.
The existing Queue clear/cancel UI test also passed. Signed Release 1.2.3 (267)
built successfully, passed strict signature verification, and was installed and
launched on Michael’s iPhone. Production revision e99c375 (PR #986); later commits
only document validation. Physical VoiceOver acceptance remains pending.

## Phone acceptance

1. In Queue options, set Group queue to None. Flick through a long Queue; check
   responsiveness, normal row speech, and position announcements when enabled.
2. Search for a subset using typing and iOS dictation. Stop dictation, navigate
   results and clear the search. Positions should refer to the full Queue.
3. Reorder and remove an episode using existing actions. Confirm positions,
   count and focus update correctly; leave and reopen Queue to confirm order.
4. Switch to Podcast and Folder grouping and back to None. Check ordering and
   existing group actions still behave normally.

Do not clear the Queue merely to test this change. No TestFlight distribution.
