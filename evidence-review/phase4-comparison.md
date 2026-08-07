# Phase 4 prediction comparison

Claims in the prediction columns are inferred unless the prediction file labels
them otherwise. Results in the measured column are measured unless explicitly
identified as a judgment or unresolved.

| Quantity | Claude Code prediction | Codex prediction | Measured result |
|---|---|---|---|
| Complexity in episode count `N` and podcast count `P` | `O(N²(1 + 1/P))`; redundant Episode pass dominates and parent cascade contributes `N²/P` | `Θ(sum(n_i²) + N + P)`; parent relationship-array maintenance dominates | The fixed-total parent ratios, `A/B = 3.344597603` and `A/C = 14.845435864`, favor a strong `sum(n_i²)` term. The single-parent doubling ratios were irregular: 3.118722797, 4.555690530, 2.047454231, and 6.866919395. These timings establish superlinear, shape-sensitive behavior but do not prove a tight asymptotic bound. |
| `t(2N)/t(N)`, `P=1` | 4.0 | 4.00 | 3.118722797 (2,500→5,000); 4.555690530 (5,000→10,000); 2.047454231 (10,000→20,000); 6.866919395 (20,000→40,000). Neither prediction described a stable measured ratio. |
| `1×40,000 / 4×10,000` | 1.6 | 4.00 | `591.892130 / 176.969609 = 3.344597603`. Codex absolute error: `|3.344597603 - 4| = 0.655402397`; Claude absolute error: `|3.344597603 - 1.6| = 1.744597603`. Measurement favors Codex. |
| `1×40,000 / 16×2,500` | 1.9 | 16.00 | `591.892130 / 39.870310 = 14.845435864`. Codex absolute error: `1.154564136`; Claude absolute error: `12.945435864`. Measurement favors Codex. |
| Current algorithm, real 10-podcast/53,864-episode point estimate | 60 seconds | 30.0 seconds | Phase 3.1: 145.774626 seconds. Claude error: 85.774626 seconds. Codex error: 115.774626 seconds. Claude is closer by exactly 30.000000 seconds. A second candidate-series sample was 121.419712 seconds, 24.354914 seconds lower; the gate uses the required Phase 3.1 value. |
| Current algorithm surprise range | 15–240 seconds | 8–180 seconds | 145.774626 seconds; both ranges contain it. No disagreement is settled. |
| Off-main actor with no feedback acceptable | No | No | Not empirically measured. The measured 145.774626-second silence is above the user-specified three-second gate, so the Phase 5 judgment is “No”; this is a judgment, not a UX measurement. |
| Silence threshold where answer flips | 3 seconds | 3.0 seconds | The task defines 3.0 seconds as the VoiceOver judgment threshold. This was not independently measured. |
| Overall remedy ranking | `(d), (c), (b), (a)` | `(d), (c), (b), (a)` | `(d)` completed fastest but is non-equivalent: 0.009515 seconds synthetic and 0.027738 real. `(c)` did not complete: it failed with `NSCocoaErrorDomain Code=134060` and deleted zero rows. On synthetic stores `(b)` 295.777705 seconds beat `(a)` 708.438257; on the real copies `(a)` 121.419712 beat `(b)` 153.079173. Both complete rankings were wrong because `(c)` failed and `(a)/(b)` order depended on shape. |
| `(d)` scope | Wider database scope; both split stores and markers removed; live contexts require replacement | Wider database scope; removes all three local models and split/repair markers; downloaded audio, artwork, preferences, and snapshots remain unless separately removed | Measured database result removed all mirrored and local model rows. Filesystem timing deliberately covered disposable store files only. The production reset’s separate audio/artwork steps were excluded by the safety gate. Migration snapshots and preferences were not part of candidate `(d)`. |
| `(c)` scope | Intended same 11-model end state if dependency ordering is correct | Intended same 11-model end state and omission of three local models | Not established because the first batch operation failed in the split-container configuration. All 11 mirrored and three local counts remained unchanged; both integrity checks were `ok`, and reopen succeeded. |
| `(b)` scope | Same as current reset | Same as current reset | Confirmed for database rows: all 11 current mirrored model types became zero and all three omitted local model counts survived on the real store copy. Filesystem scope was skipped by the safety gate. |
| `(a)` scope | Current scope | Current scope | Confirmed for database rows: all 11 current mirrored model types became zero and all three omitted local model counts survived on the real store copy. Filesystem scope was skipped by the safety gate. |

## Disagreements

- Parent-shape model: the measurements favor Codex. For A/B, Codex was closer
  by `1.744597603 - 0.655402397 = 1.089195206` ratio units. For A/C, Codex was
  closer by `12.945435864 - 1.154564136 = 11.790871728` ratio units.
- Real-shape point estimate: the Phase 3.1 measurement favors Claude by exactly
  `115.774626 - 85.774626 = 30.000000` seconds. Both prediction ranges include
  the result, so the range disagreement remains unresolved.
- Complexity: the fixed-total parent discriminator favors Codex’s dominant
  parent-array term. The irregular doubling series does not establish either
  exact complexity expression, so the tight bound remains unresolved.

## Items both predictions got wrong

- Both predicted a stable 4.0 doubling ratio. The four observed ratios ranged
  from 2.047454231 to 6.866919395 and did not form a stable 4.0 series.
- Both ranked the completing remedies `(d), (c), (b), (a)`. Candidate `(c)` did
  not complete in either shape; it failed and deleted zero rows. The `(a)/(b)`
  ordering also reversed between the one-parent synthetic and ten-parent real
  shapes.
- Both point estimates materially understated the required Phase 3.1 time:
  Claude by 85.774626 seconds and Codex by 115.774626 seconds.

## Claude Code item F, verbatim, with Codex disposition

> **1. "24 SwiftData frames and RangeReplaceableCollection.removeAll(where:)" (earshot-migration-report.md, OPEN DEFECT section; identical text in migration-state.md, OPEN DEFECT section) is a composite that matches neither crash report individually.** Counting `imageIndex:3` (SwiftData) frames directly: Report 1 (193440) has **18** SwiftData frames, and its preceding libswiftCore frames *do* include `_halfStablePartition`/`removeAll(where:)`. Report 2 (194039) has **24** SwiftData frames, but its preceding libswiftCore frame is a plain `swift_release` — no partition or `removeAll` anywhere in that trace. The docs' single sentence attributes "24 frames" + "removeAll(where:)" as if it describes one unified signature, but that combination is present in neither report as stated — 24 frames belongs to the report without removeAll, and removeAll belongs to the report with 18 frames. This is a factual, independently verifiable inaccuracy, and it matters diagnostically: the two incidents are dying at two genuinely different points in SwiftData's internals (bulk array compaction vs. ARC teardown), which is worth knowing precisely rather than blurring into one description, since it bears on where the O(n)-per-touch cost is actually coming from.

**Disposition: agree.** Direct frame counts establish the composite wording is
imprecise. The tracked document copies will distinguish report 1’s 18 SwiftData
frames plus `removeAll(where:)` from report 2’s 24 SwiftData frames plus
`swift_release`.

> **2. Unreconciled episode-count discrepancy.** The OPEN DEFECT section (both docs) states the delete "runs on the main thread over roughly 53,864 episodes." Elsewhere in the *same documents*, the presumably-same 10-podcast production store is repeatedly and precisely measured at **53,946 episodes** (e.g., migration-state.md "Preserved fixtures → Public build-155 V5 production shape": "10 podcasts and 53,946 episodes"; earshot-migration-report.md "Real build-155 V5 fixture": "10 subscriptions and 53,946 episodes"). That's an 82-episode gap the documents never explain. There's a plausible reconciling fact sitting elsewhere in the same document — "The production V5 store contained 86 duplicate episode GUID pairs... Per-podcast identity repair removed the duplicates afterward" — but 53,946 − 86 = 53,860, still 4 off from 53,864, and neither document draws this connection or otherwise accounts for the gap. Given how precisely everything else in these documents is measured and cited (down to individual 4,096-byte blocks), an unexplained, uncited "roughly 53,864" sitting next to a repeatedly-verified exact 53,946 is worth flagging as stale/imprecise.

**Disposition: agree that it is unresolved at Phase 4.** Phase 6.3 performs the
required disposable-copy reconciliation. No conclusion is forced here.

> **3. Omission, not an error: the docs don't connect this defect to the codebase's own established fix pattern.** PR #785 ("Run store migration off the main actor") and #786 ("Move store preparation off the launch watchdog path") are presented as foundational, already-merged architecture specifically for avoiding main-actor scene-update watchdog kills during large-graph persistence work. The OPEN DEFECT section never notes that `SettingsReset.deleteAllLocalData` is exactly the class of operation #785/#786 were built to keep off the main actor, and simply wasn't. This isn't factually wrong, but given how carefully both documents cross-reference every other PR and issue against current defects, its absence here is a notable gap for anyone using these docs to scope the fix.

**Disposition: agree as an editorial omission, not as a factual defect.** The
source and crash reports establish the reset’s synchronous main-actor path; the
migration engine provides the existing architectural comparison. This does not
by itself authorize reusing migration snapshot or quarantine semantics for a
Settings reset.
