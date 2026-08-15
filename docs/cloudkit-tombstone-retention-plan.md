# CloudKit tombstone retention plan

Status: approved design follow-up; intentionally deferred beyond Earshot 1.1
Approved by: Michael, 2026-08-14

## 1.1 decision

Earshot 1.1 retains compact-projection tombstones indefinitely. It must not
physically delete a tombstone merely because `deletedAt` is older than a fixed
duration. A device that was offline longer than that duration could otherwise
upload stale live state and resurrect deleted subscriptions, queue entries,
bookmarks, listening sessions, folders, settings, or episode state.

This is not a blocker for the 1.1 schema. The records are compact, and retaining
them favors correctness while Production growth is still unknown.

## Follow-up design

1. Add local, privacy-preserving diagnostics for projection counts, tombstone
   counts by entity, oldest tombstone age, and compact-store size. Do not add
   analytics or transmit these measurements.
2. Establish a Production baseline before choosing a retention period. Start
   evaluation in the 180-to-365-day range rather than assuming a short window.
3. Add an additive synchronization-generation field and an account-level
   current-generation marker in a later schema revision.
4. Prevent a stale device from publishing until it has fetched and reconciled
   the current generation. If its generation is obsolete, rebuild its compact
   projection from the current CloudKit state before enabling publication.
5. If acknowledgements are used, maintain anonymous device leases and sync
   watermarks. Treat devices beyond the lease window as stale and require the
   same rebuild-before-publish path when they return.
6. Purge only tombstones that are outside the selected retention period and
   cannot be resurrected by any valid publishing generation. Make cleanup
   incremental, restartable, and idempotent.

## Required validation before enabling cleanup

- A device returns after being offline longer than the retention window.
- A stale device contains a live value for a remotely deleted record.
- Delete and edit occur concurrently on different devices.
- The app is force-quit during cleanup and during the required rebuild.
- The app is reinstalled, the iCloud account changes, or CloudKit is temporarily
  unavailable.
- Device clocks disagree substantially.
- Cleanup handles large listening-history and queue tombstone populations in
  bounded batches without harming VoiceOver responsiveness.

Physical deletion remains disabled until these protections and tests exist.

