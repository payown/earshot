# ADR 004: The Flutter→SwiftUI migration restores state and queue, not just subscriptions

- **Status:** Accepted. Amends ADR 003 — the "subscriptions only" scope in that
  decision is superseded; everything else in ADR 003 (same bundle id, local-db
  read, clean go-forward SwiftData store) still stands.
- **Date:** 2026-06-23
- **Deciders:** Michael Babcock (Payown Media LLC)
- **Issues:** #426 (PR #428 — queue + self-heal), #429 (PR #430 — manual
  re-import), building on #427. Supersedes the scope note in ADR 003.

## Context

ADR 003 decided the SwiftUI app would take over the Flutter bundle id and, on
first launch, read the leftover drift database at `Documents/earshot.db` and
migrate **subscriptions only** — every other field would be re-derived from the
live feed. In practice that left returning testers feeling like the upgrade
"lost their setup": their played/unplayed history, what was sitting in the
inbox, their listening positions, and their play queue were all still present in
`earshot.db` but were never read. The audit that preceded this ADR confirmed the
data was there and recoverable, and that the App Group / export-writer approach
ADR 003 already abandoned is genuinely gone (no `earshot_export.db` exists). So
the cost of restoring this state is only "read more columns from a database we
already open," not new cross-app plumbing.

## Decision

The migration reads the **full** Flutter drift database read-only at
`Documents/earshot.db` (direct SQLite3, no App Group, no export writer) and
restores the per-episode state a live feed can't re-derive, in addition to the
subscription list. Episodes are matched by `guid` first, `audioURL` as a
fallback. Completion is tracked so a failed or partial import self-heals on a
later launch, and a user-initiated re-import is available any time from
Settings → Data.

| Data (table in `earshot.db`) | Restored? | How |
|---|---|---|
| Subscriptions (`podcasts`) | Yes | Re-subscribed as labeled show shells; episodes re-fetched live |
| Played / unplayed (`episodes.status`) | Yes | Overlaid onto re-fetched episodes |
| Inbox membership (`episodes.status` + `inbox_dismissed`) | Yes | Overlaid (only genuinely-in-inbox rows resurface) |
| Listening position (`episodes.position_seconds`) | Yes | Overlaid |
| Queue order (`queue_items`) | Yes | Re-added in `position` order via the normal queue path |
| Downloads, folders, bookmarks, listening history, per-podcast settings | No | Re-derived from feeds, or not migrated (out of scope) |

## Consequences

Returning testers keep their history and queue automatically, with the same
"install over the top, no uninstall" device-verification requirement as ADR 003
(still not provable in CI). The migration now reads three tables instead of one,
all read-only and guarded (missing file/columns no-op, never crash). A partial
or missed import is no longer a dead end: it self-heals when the store is empty
or state is missing, and Settings → Data exposes a manual re-import that is
idempotent (no duplicate shows or queue items). Data not in the table above is
intentionally left to re-derive from live feeds or is deferred to a future
issue.
