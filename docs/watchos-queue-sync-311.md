# Paired queue synchronization, 1.2.6 (311)

## Listener report and code finding

Michael reported on physical Apple Watch build 309 that the watch queue did not appear to match the iPhone queue. He has not yet checked this behavior in build 310. StartTesting item `c704f1ae-d6bf-43d1-ac69-b784f3a6191b` remains open for hardware acceptance.

Build 310 already had durable, per-device CloudKit queue contributions and conflict clocks, but watch foreground did not promptly exchange queue data with the phone. Watch local queue mutations used a 120-second coalesced sync, and the watch did not observe CloudKit imports while foreground. A queued episode absent from the watch catalog could be skipped when its newest ordering contribution lacked media metadata. These are code findings that plausibly explain the report; the exact on-device delivery failure has not been reproduced in the simulator.

## Change and ownership

Each device continues to own and publish its own CloudKit queue contribution. A versioned, paginated Watch Connectivity snapshot accelerates the same per-device rows when the peer is reachable. Both sides request a snapshot on activation and reconnection; queue changes send an immediate invalidation that triggers a new request. A manual Refresh Queue action reports success, failure, or unavailability. Reachability is checked for each request, and requests have a 15-second timeout. Offline queue actions remain local and are reconciled later by the existing CloudKit projection or the next paired exchange.

Received paired contributions persist in a local JSON overlay. Applying them to the visible queue does **not** insert another device's records into the receiving device's mirrored SwiftData/CloudKit store. This avoids duplicate CloudKit records and preserves each device's ownership. The phone's first-run queue bootstrap excludes keys already imported through the paired overlay, while durable local intents still publish normally. Membership and order clocks merge separately; a delayed reorder cannot revive an explicitly removed item. Snapshot pages are validated, size-bounded, and rejected on version or sequence mismatch. The overlay retains a received contribution across relaunch while CloudKit delivery is delayed; no SwiftData schema or entitlement changed.

The watch builds a playable queue shell from metadata in any contribution for that episode and uses a stable identity tie-breaker for equal positions. A queued episode does not require a local audio download. The phone creates an episode shell for a queued item missing from its catalog when the podcast is followed. Queue refresh precedes handoff preparation, and a failed refresh prevents the transfer; the source keeps playing.

## Accessibility and verification

The queue status and Refresh Queue control have spoken labels and explicit feedback. The iPhone playback section retains its earlier focus order. Removing or reordering a watch queue item returns focus to the Up Next heading. The watch queue row announces its podcast and queue position. The repository accessibility review found the status, focus and manual-refresh gaps; those code findings were addressed. Physical VoiceOver focus and announcement timing remain unverified.

Deterministic tests cover paged transport, stale reorder versus removal, duplicate delivery, no peer-created CloudKit row, two-way contribution exchange, offline concurrent additions, queue persistence across watch relaunch, and existing CloudKit conflict resolution. Simulator results and signed distribution evidence are recorded in `docs/watchos-progress.md` after the final run. Watch Connectivity delivery, CloudKit import timing and handoff still require two physical devices.

The paired queue path uses each app's existing CloudKit projection to preserve conflict clocks. If that projection cannot open or the phone's CloudKit account is unavailable, the local queue still works and Refresh Queue reports the limitation; cross-device queue changes wait for projection recovery. This case remains a limitation for the physical test, not a claimed successful sync.

## Physical acceptance

Use step 9 of `docs/watchos-device-testing.md` during the single integrated VoiceOver session. It includes exact queue actions, expected results, and what to report if an item is missing or reappears.
