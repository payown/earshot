# Sync A2 identity and duplicate repair

**Status:** Implemented and locally verified (2026-08-03)

**Parent plan:** [folders-sync-phase-a.md](folders-sync-phase-a.md), Task 2

This record defines the application-level identity guarantees that replace
SwiftData uniqueness constraints in the CloudKit-compatible schema. It changes
no model, entitlement, capability, configuration, or user interface.

## Natural keys

- Podcast: canonical feed URL.
- Episode: canonical podcast feed URL plus episode GUID. A GUID alone is never
  global identity.
- App setting: exact key, with canonical feed URLs in the two per-podcast key
  families.

Feed URL canonicalization is intentionally conservative. It trims surrounding
whitespace, lowercases HTTP/HTTPS scheme and host, removes default ports and
fragments, and preserves path, query, percent encoding, and their case. The
same rule is used by Subscribe, background feed work, OPML, directory Search,
notification routing, V1 reimport, per-podcast settings, and persisted episode
download/playback keys.

## Write convergence

Podcast creation always fetches by canonical identity before inserting. An
app-wide async gate serializes creation for the same canonical URL across
independent SwiftData contexts and remains held through `ModelContext.save()`.
This closes the in-process fetch/insert race after `.unique` is removed. A
second writer rechecks after the first commit and returns the existing row.

The gate does not pretend to serialize other devices. Rows arriving from future
CloudKit mirroring converge through the deterministic repair pass below.

Setting writes fetch every matching row, apply the caller's explicit new value
to a deterministic survivor, canonicalize its key, and delete the duplicate
rows in the same save. An explicit write therefore always wins.

## Deterministic repair policy

The oldest podcast or episode identity (`createdAt`, then persistent identifier)
survives so references remain stable. Podcast metadata and explicit preferences
come from the newest duplicate where available; subscription creation time uses
the oldest value, while refresh and high-water timestamps use the maximum.

For duplicate episodes within one podcast:

- freshest feed metadata wins;
- maximum playback position and played timestamp survive;
- played and dismissed user state survive;
- a queue relationship is authoritative and the earliest queue position is kept;
- bookmarks, listening sessions, podcast/episode folder memberships, and recent
  expiration state are retargeted;
- duplicate relationship rows are collapsed deterministically;
- any nonempty downloaded-audio path is preserved and produces terminal
  `.downloaded` state; active-transfer rows are reconciled to that state.

Episodes with the same GUID in different podcasts are never grouped or merged.
For legacy duplicate settings that have no timestamp, the persistent-identifier
order chooses a stable survivor; the next explicit setting write remains
authoritative and self-heals the group.

## Bounded execution

`repairAll()` reads the small Podcast and AppSetting tables. It reads Episode
rows only for a canonical feed URL that has duplicate Podcast rows. Known
single-podcast mutation paths use targeted repair for that podcast. The bounded
test creates 1,000 episodes across 50 unique podcasts and proves the general
pass inspects zero episodes.

Task 2 provides and exercises this repair service but does not run a destructive
general pass during an ordinary V6 launch. Task 3 will invoke it inside the
backed-up, restartable V7/V8 migration before uniqueness constraints disappear.
This keeps repair recoverable and avoids doing migration work ad hoc on launch.

## Verification coverage

Tests cover conservative/idempotent URL canonicalization, repeated and
concurrent subscribe, repeated settings writes, canonical Search-result dedup,
download-key compatibility, V1 reimport convergence, targeted repair, bounded
general repair, full relationship retention, idempotent second repair, and the
same-GUID/different-podcast boundary. The V8 migration suite in Tasks 3–4 will
repeat convergence against an on-disk schema with database uniqueness removed.
