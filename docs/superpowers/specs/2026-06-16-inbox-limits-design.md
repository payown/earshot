# Per-podcast inbox limits — design

**Date:** 2026-06-16
**Issues:** #320 (per-podcast inbox episode-count cap), #319 (per-podcast inbox age limit)
**Status:** Approved design, pending implementation plan

## Problem

The inbox has no way to limit how much of a given show piles up:

- **Count:** a VoiceOver beta tester asked to keep only the latest episode (or few)
  from a high-frequency show in the inbox.
- **Age:** time-sensitive shows (e.g. daily news) go stale fast — their episodes
  should be able to drop out of the inbox automatically after a set time.

Today the only count behavior is a hardcoded anti-flood seed (`inboxLimit: 3`)
applied **only at initial subscribe**; there is no ongoing cap, no age limit,
and nothing is per-podcast or user-configurable. Per-podcast **queue** age
expiration already exists (`podcasts.queueAgeLimitDays` + `QueueExpirationService`)
and is the precedent this mirrors.

## Decisions (all confirmed)

1. **Two independent limits**, both per-podcast, both on the podcast settings
   page in the Library:
   - **Count cap** — keep at most N newest episodes per podcast in the inbox.
     Has a **global default** (the new setting Michael asked for) plus a
     per-podcast override.
   - **Age limit** — remove inbox episodes older than X. **Per-podcast only,
     default Off** (no global default — a global age limit would surprise users
     by dropping episodes from shows they meant to keep).

2. **Count cap global default = "No limit."** Caps are opt-in. This means no
   existing tester's inbox is trimmed on the upgrade that ships this.

3. **Subscribe-time anti-flood is preserved and separate.** Subscribing to a
   show with a large back catalog still seeds only a few episodes into the inbox
   (the rest filed played), regardless of the ongoing cap. When a finite count
   cap *is* set (global or per-podcast), subscribe seeding uses that cap instead
   of the default 3, so the two stay coherent.

4. **Age granularity = preset list including sub-day options**, stored
   internally as hours: Off / 6h / 12h / 1 day / 3 days / 1 week / 2 weeks. No
   free-form entry (easier on VoiceOver).

5. **Removal is silent and non-destructive.** A trimmed episode is hidden from
   the inbox (`inboxDismissed = true`) but keeps `status = newEpisode`, stays
   unplayed, and remains in the show's episode list (playable/queueable there).
   No "recently expired" restore list for the inbox.

6. **Tighten now, don't reverse.** Lowering the cap or setting an age limit
   trims immediately (and keeps trimming on refresh / launch / resume). Raising
   or clearing a limit does **not** bring previously-trimmed episodes back — we
   can't distinguish an auto-trim dismissal from a user "Clear inbox" dismissal
   (same constraint as #298), so enforcement only ever *adds* dismissals.

## Data model

Schema bump **v14 → v15**, additive only (two nullable columns, no backfill):

- `podcasts.inboxMaxEpisodes` — `int().nullable()`. Per-podcast count override.
  `null` = use global default.
- `podcasts.inboxAgeLimitHours` — `int().nullable()`. Per-podcast age limit.
  `null` = Off.

Global setting in `app_settings` (key/value, following the existing retention
settings pattern):

- key `inbox_default_max_episodes`. Value is an int, or a sentinel for
  "No limit" (e.g. absent / `null` string). Default = No limit.

Migration: `m.addColumn` for both columns under `if (from < 15)`. Pure additive
DDL on existing table; no data transform (lowest-risk migration class). Covered
by an upgrade-path test per the DB-migration rules.

## Effective-limit resolution

- **Effective count cap** for a podcast = `inboxMaxEpisodes ?? globalDefault`.
  If that resolves to "No limit", no count trimming for the podcast.
- **Effective age limit** = `inboxAgeLimitHours` (per-podcast only). `null` = Off.

## Enforcement — `InboxLimitService`

A new service mirroring `QueueExpirationService`, with one entry point
`applyInboxLimits()` that iterates inbox-included podcasts and, for each:

An episode is **trim-eligible** only when: `status = newEpisode` AND
`inboxDismissed = false` AND `positionSeconds = 0`. The `positionSeconds = 0`
clause matters because an episode the user started playing from the inbox can
still be `newEpisode` with a saved position — that's "engaged with" and must not
be trimmed.

1. **Age pass** (if age limit set): set `inboxDismissed = true` for trim-eligible
   episodes where `pubDate < now - ageLimit`.
2. **Count pass** (if effective cap is finite): among the podcast's
   trim-eligible episodes ordered by `pubDate` desc (id as tiebreak), keep the
   newest N; set `inboxDismissed = true` on the remainder.

Constraints applied throughout:
- Only inbox-included podcasts (respect inbox opt-in/exclude, like the rest of
  the refresh path).
- Only ever sets `inboxDismissed = true`; never clears it; never changes
  `status`, `pubDate`, `positionSeconds`, or the high-water mark.
- The trim-eligible filter excludes everything the user engaged with: played
  (`played`) and queued (`inQueue`) aren't `newEpisode`; started episodes are
  excluded by `positionSeconds = 0`.

**Run triggers:**
- On launch / resume — alongside the existing `QueueExpirationService` run
  (so age limits take effect as time passes, with no refresh needed).
- After each feed refresh (new arrivals can push older ones past the cap).
- Immediately when a relevant setting changes (global default, or a podcast's
  count/age value), for instant feedback.

**Performance — protect the #278 cold-launch win (required).** #278 made the
inbox reachable on cold launch by doing *less* work; a per-podcast enforcement
loop on launch/resume would risk regressing exactly that, especially on 100+
feed libraries. Therefore:
- The pass must **early-out** before touching any podcast when no limits are in
  effect: a single cheap query for "is the global default finite, OR does any
  podcast have a non-null `inboxMaxEpisodes` or `inboxAgeLimitHours`?" If not,
  return immediately. With the shipping defaults (global No limit, age Off) this
  is the common case and every existing user on upgrade hits it — so launch does
  effectively zero extra work.
- Trimming must be **set-based SQL** (bulk `UPDATE ... WHERE`), not a per-row
  Dart loop, and must use the existing `idx_episodes_inbox` index.
- A perf sanity check against the 58-feed sample OPML is part of acceptance:
  cold launch with limits unset must be no slower than today; with limits set,
  the pass stays off the critical path to inbox interactivity.

**Ordering within a single refresh pass (required).** Multiple writers touch
`inboxDismissed` in one refresh. The canonical order is:
`_upsertEpisodes` → inbox-exclude dismissals → #298 resurrection → high-water
mark advance → **inbox-limit trim (this service) last**. Running the trim last
means it sees the final post-resurrection state, so a republished episode that
#298 just brought back but which is now beyond the count cap (or past the age
cutoff) is correctly re-trimmed in the same pass. This ordering is tested
end-to-end (republished-but-over-cap episode).

## Subscribe-time behavior

`_upsertEpisodes`'s subscribe seeding uses the effective count cap when finite,
otherwise the existing anti-flood default (3). Episodes beyond the seed are
inserted `played` as today (anti-flood), unchanged.

## UI

Both surfaces follow existing settings-row semantics and get a
`mobile-accessibility` review before merge.

- **Global:** Settings → Inbox settings → "Default episodes per podcast in
  inbox": No limit / 1 / 3 / 5 / 10.
- **Per-podcast:** Podcast settings (Library → podcast):
  - "Episodes in inbox": Use default / 1 / 3 / 5 / 10.
  - "Remove from inbox after": Off / 6 hours / 12 hours / 1 day / 3 days /
    1 week / 2 weeks.

## `inboxDismissed` writer/reader audit (REQUIRED first implementation task)

`inboxDismissed` is a single un-attributed boolean already written by several
features, and #298 established we cannot tell those dismissals apart. This
feature adds two more writers (count cap, age limit), so before writing the
service the implementer must audit and document, in the plan, every place that
reads or writes `inboxDismissed`, including at least:

- backlog auto-dismiss (`_upsertEpisodes`)
- Clear Inbox (`clearInbox`)
- inbox include/exclude (`_setEpisodeDismissed` / `setInboxIncluded` /
  `setInboxExcluded`) — note this has a **restore direction** that sets
  `inboxDismissed = false`
- #298 resurrection (sets `false`)
- dismissFromInbox
- the inbox stream + badge count (readers; cf. #278)

The key risk to resolve: the inbox include/exclude **restore direction** clears
`inboxDismissed` for a podcast. After re-including a podcast, that would
**un-trim** episodes the count/age limit had hidden — silently reversing a trim,
which contradicts "tighten now, don't reverse," and could resurface a flood.

**Decision to lock during the audit (default):** treat re-include as a
deliberate user action that resets inbox visibility, and immediately re-run the
inbox-limit trim for that podcast right after the restore, so the net result
respects the active limits. I.e. include/exclude restore is allowed to clear the
flag, but the trim pass runs again so limits are re-applied and the user never
sees more than the cap. The audit confirms no other writer needs attribution; if
it turns out one does, introduce a dismissal-reason column **now** rather than
discovering it mid-implementation.

## Interactions / non-conflicts

- **#298 resurrection** only touches `status = played` rows; trimmed episodes
  stay `newEpisode`, so they are never wrongly resurfaced. Ordering (above) runs
  the trim after resurrection so an over-cap republished episode is re-trimmed.
- **#296 high-water mark** is untouched (we never change `pubDate` or the mark).
- **Inbox include/exclude restore** is handled by the audit decision above
  (re-run the trim after a restore).
- **`inboxDismissed`** is already the inbox-visibility flag used by Clear Inbox
  and backlog dismissal, so trimming reuses existing inbox-query semantics.

## Testing

- Migration v14 → v15 adds both columns, data intact (upgrade-path test).
- Count cap: trims to N newest; respects per-podcast override of global default;
  "No limit" trims nothing; ignores played, queued, and started
  (`positionSeconds > 0`) episodes; inbox-excluded podcast untouched.
- Age limit: trims episodes older than the cutoff; Off trims nothing; a started
  (`positionSeconds > 0`) but still-new episode past the cutoff is NOT trimmed;
  boundary (exactly at cutoff) is well-defined; future-dated not trimmed oddly.
- Tighten-now-don't-reverse: lowering a cap trims immediately; raising it does
  not restore.
- Subscribe seeding honors a finite effective cap; falls back to 3 when No limit.
- Enforcement triggers: runs on refresh and on settings change.
- Ordering: a republished episode (#298) that is over the cap or past the age
  cutoff is re-trimmed in the same refresh (trim runs last).
- Include/exclude restore: re-including a capped podcast does not leave more than
  the cap visible (the trim re-runs after restore).
- Performance: with no limits set anywhere, the launch/resume pass early-outs and
  does no per-podcast work (guard against a #278 regression); verified against
  the 58-feed sample OPML.

## Out of scope

- Restore list / "recently expired" for the inbox.
- Global age-limit default.
- Exposing these as Quick Actions (separate concern; cf. #261 for the queue).
