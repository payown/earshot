# Performance and scale rules

Earshot's heavy users follow hundreds of podcasts with thousands of unplayed
episodes. Code that is fine on a small test library can melt a real device.
Two production incidents came from the SAME blind spot — expensive work on a
high-frequency path that scaled with library size:

- **#731 / #732** — the Inbox tab badge re-materialized the whole episode table
  on every 5-second position save. On a large library iOS killed the app under
  `cpu_resource_fatal` about a minute into playback.
- **#736** — the follow-up fix bounded that query to `playedAt == nil`, which
  stopped the *crash* but left an O(unplayed-backlog) fetch running on every
  save. At 15k unplayed episodes that was ~510 ms of main-thread work per save,
  ~18 times a minute at 1.5x — the phone ran hot after an hour of playback.

The lesson from #736 specifically: a perf/CPU fix was judged by "does it still
crash" instead of "how does it scale." Those are different questions.

## Rules

1. **Identify high-frequency paths and treat them as hot.** These run many times
   per minute during normal use:
   - the playback tick / position save (`PlayerService` — every ~1s of playback,
     saves every ~5s, and BOTH scale up with playback rate: at 1.5x they fire
     ~1.5x more often in wall-clock),
   - anything invalidated by a SwiftData `@Query`,
   - list-row bodies, `.onChange`, `.task(id:)`, and any per-frame closure.

   On a hot path, no operation may be O(library size). Reads must be bounded,
   cached, or store-level counts — never "fetch everything then filter/reduce in
   Swift."

2. **SwiftData `@Query` invalidates on EVERY context save, app-wide.** A single
   position save re-runs every live `@Query` in the tree and pays its full fetch
   cost. Never drive a large or relationship-walking `@Query` from a view that is
   mounted during playback. For an aggregate (a badge count, a total), prefer a
   store-level `fetchCount` (SQL COUNT, no object materialization), and only pay
   a full fetch when a cheap change-detector says the set actually changed — a
   position save must not trigger it.

3. **A perf/CPU/crash fix is not done until you've measured the RESIDUAL cost at
   scale.** "It no longer crashes" and "it no longer force-quits" are not the bar.
   Seed a heavy-user library (hundreds of podcasts, 10k+ episodes) and measure the
   per-operation cost and its frequency. If a hot-path operation is still O(N),
   the fix is incomplete.

4. **Every hot-path data operation ships with a scale regression test.** Seed a
   realistic large store and assert the per-operation cost stays bounded (a
   store-level count, not an object materialization; a fixed number of fetches,
   not one-per-item). `EarshotTests/InboxBadgeCostTests` is the template: it
   quantifies per-save cost at small vs. large scale and asserts the cheap path
   stays >=10x cheaper than the naive one. These tests are CI gates — a
   regression to O(backlog) must fail the build, not reach a TestFlight tester.

5. **When you touch a hot path, say so in the PR.** State what runs per tick /
   per save / per row, and why it is bounded. Reviewers should reject a hot-path
   change that can't answer "how does this scale to 10k episodes?"

## Quick check before merging anything on a hot path

- Does this run per playback tick, per position save, per `@Query` invalidation,
  or per list row? If yes, it's hot.
- Is any read O(library size)? Replace with a bounded/store-level operation.
- Is there a scale test seeding 10k+ episodes that asserts bounded cost?
- If this is a perf/crash fix: did I measure the residual at scale, or just
  confirm the fatal symptom is gone?
