# Codex pre-registered predictions

These predictions were written before any Phase 3 measurement was created or run.

## C. Complexity and numeric predictions

**Inferred.** I predict that the dominant cost is removing each Episode from its
parent Podcast's to-many relationship array during SwiftData cascade and inverse
maintenance. For per-podcast episode counts `n_i`, I predict
`T = Θ(sum(n_i²) + N + P)`. With one podcast this is `Θ(N²)`; with an evenly
distributed fixed total it falls approximately in proportion to podcast count.

- Predicted `t(2N)/t(N)` at fixed `P=1`: **4.00**.
- Predicted time ratio, `1 × 40,000` divided by `4 × 10,000`: **4.00**.
- Predicted time ratio, `1 × 40,000` divided by `16 × 2,500`: **16.00**.
- Predicted current-implementation completion time for 10 podcasts and 53,864
  episodes on the modern Mac simulator: **30.0 seconds**.
- Range I would be surprised to fall outside: **8.0–180.0 seconds**.

## D. Off-main acceptability for VoiceOver

**Inferred. No.** Moving the same work off the main actor would prevent the
scene-update watchdog, but a blind VoiceOver user would receive no confirmation
that the destructive operation is still running. My acceptability threshold is
**3.0 seconds** of silence after confirmation. My 30.0-second point estimate is
ten times that threshold.

## E. Candidate ranking

**Inferred, fastest first: (d), (c), (b), (a).**

1. **(d) Tear down the ModelContainer and remove store files.** Predicted
   `Θ(1)` in row count. It widens database scope: removing both V10 stores also
   removes `LocalPodcastState`, `LocalEpisodeState`, `LocalAppSetting`, split and
   repair markers, and any other rows in those stores that the current reset
   omits. It still does not itself remove downloaded audio, artwork, preferences,
   or migration snapshots unless those are separately included.
2. **(c) SwiftData batch delete by model type in dependency order.** Predicted
   `Θ(N)` store work without per-object Swift materialization. If restricted to
   the same eleven mirrored types and verified for relationship behavior, it can
   preserve current database scope. It does not correct the current omission of
   the three V10 device-local model types.
3. **(b) Delete Episodes explicitly before Podcasts.** Predicted to retain the
   same entity scope and filesystem intent as current code while reducing the
   parent cascade/inverse-array cost; it remains per-object and therefore remains
   superlinear under my model.
4. **(a) Current implementation, Podcasts first.** Predicted slowest because the
   Podcast cascade begins with populated episode arrays and is followed by the
   explicit Episode pass before the single save.
