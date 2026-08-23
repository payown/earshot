# Earshot build 215 and backlog audit

> Generated 2026-08-22 after merging builds 215 and 216 and reviewing every open issue against current `main`.

## Outcome

Build 215 is merged, fully tested, and confirmed on Michael's iPhone. Build 216
then closed the highest-priority autonomous follow-up and supplied physical
evidence for another previously implemented bug. Ten stale, completed, or newly
verified issues are closed in this sweep. Twenty-six applicable issues remain,
with explicit priorities and autonomy/sign-off dispositions.

## Build 215 delivery

| Issue | Result |
| --- | --- |
| [#729](https://github.com/payown/earshot/issues/729) | Closed. Added bounded, restart-safe Inbox dismissal backfill for played history while preserving natural-completion behavior. |
| [#710](https://github.com/payown/earshot/issues/710) | Closed. Downloads are idempotently excluded from iCloud/iTunes backup, including an existing directory. |
| [#711](https://github.com/payown/earshot/issues/711) | Evidence phase shipped. Read-only WAL measurements now run before store open, around full refresh, and on background. The issue stays open until measurements justify a checkpoint policy. |

Verification: 1,913 tests passed with 28 expected skips and zero failures; GitHub
CI passed; Release build 1.2.0 (215) built, installed, and launched on the
physical iPhone.

## Additional autonomous completion

Build 216 closed [#823](https://github.com/payown/earshot/issues/823) with a
bounded 40-record atomic seed-marker journal and notice-level local logging.
Focused tests and CI passed. On-device collection then proved that all 229 local
listening sessions have exact active semantic projection matches, with zero
missing and zero duplicate semantic groups. Both copied stores passed SQLite
integrity; the durable evidence is in
`docs/device-test-artifacts/2026-08-22-build-216-projection-evidence.md`. This
closes [#819](https://github.com/payown/earshot/issues/819).

## Closed issue inventory

| Issue | Closure basis |
| --- | --- |
| [#390](https://github.com/payown/earshot/issues/390) | Current trunk uses Swift 6 with complete strict concurrency. |
| [#513](https://github.com/payown/earshot/issues/513) | Download state and auto-download behavior are implemented; remaining product wording is isolated in #719. |
| [#524](https://github.com/payown/earshot/issues/524) | Obsolete Flutter-era cleanup superseded by current schema and #834. |
| [#616](https://github.com/payown/earshot/issues/616) | Earshot Plus product catalog, caps, purchases, restore, and entitlement handling are implemented. |
| [#617](https://github.com/payown/earshot/issues/617) | Planning placeholder superseded and completed by #636's shipped tip jar. |
| [#695](https://github.com/payown/earshot/issues/695) | Route-change protection and later time-domain restoration are implemented and covered. |
| [#710](https://github.com/payown/earshot/issues/710) | Completed by build 215 / PR #870. |
| [#729](https://github.com/payown/earshot/issues/729) | Completed by build 215 / PR #870. |
| [#823](https://github.com/payown/earshot/issues/823) | Completed by build 216 / PR #871. |
| [#819](https://github.com/payown/earshot/issues/819) | Implementation plus physical exact semantic-convergence evidence complete. |

## Remaining priorities

### High — evidence, stability, and security

| Issue | Next action and autonomy |
| --- | --- |
| [#709](https://github.com/payown/earshot/issues/709) | Implement telemetry-free cleartext-media measurement autonomously. Warning UX and ATS removal require measured compatibility evidence and explicit review. |
| [#711](https://github.com/payown/earshot/issues/711) | Collect build-215+ WAL sizes across refresh/background/relaunch and correlate with Michael's VoiceOver latency measurements before any checkpoint code. |
| [#696](https://github.com/payown/earshot/issues/696) | Main OOM drivers are fixed; remaining acceptance requires a representative 300+ feed physical import/relaunch run. |
| [#801](https://github.com/payown/earshot/issues/801) | Requires a controlled physical V6 migration fixture and attributed storage evidence; do not run destructively against Michael's live store. |

### Medium — meaningful features or remaining test gaps

| Issue | Disposition |
| --- | --- |
| [#835](https://github.com/payown/earshot/issues/835) | Bounded Download All UI; requires exact-scope confirmation and VoiceOver semantics approval. |
| [#834](https://github.com/payown/earshot/issues/834) | Quick Action enable/disable changes rotor semantics; requires explicit semantics approval. |
| [#824](https://github.com/payown/earshot/issues/824) | Independent Inbox dismissal plus sync changes actions and projection policy; requires product/semantics approval. |
| [#719](https://github.com/payown/earshot/issues/719) | Product decision on auto-download scope and copy. |
| [#718](https://github.com/payown/earshot/issues/718) | Product/focus decision for natural completion versus queue auto-advance. |
| [#717](https://github.com/payown/earshot/issues/717) | Transcript export placement and output policy need selection; implementation is otherwise bounded. |
| [#690](https://github.com/payown/earshot/issues/690) | Real low-frequency reset teardown defect, but `SettingsReset` is protected scope and needs explicit sign-off. |
| [#686](https://github.com/payown/earshot/issues/686) | Requires a real iPad, layout/VoiceOver QA, screenshots, and device-family approval. |
| [#571](https://github.com/payown/earshot/issues/571) | Volume-boost DSP and limiter need an audio architecture spike and device listening validation. |
| [#570](https://github.com/payown/earshot/issues/570) | Silence-trimming DSP is a larger audio project with stats and device-quality validation. |
| [#552](https://github.com/payown/earshot/issues/552) | Total-duration presentation changes spoken row output and needs semantics approval. |
| [#551](https://github.com/payown/earshot/issues/551) | App Intent implementation is autonomous after command vocabulary and parameter policy are approved. |
| [#550](https://github.com/payown/earshot/issues/550) | Needs product choice between saved template and recurring queue builder. |
| [#465](https://github.com/payown/earshot/issues/465) | Per-podcast editor Quick Actions remain absent; action/rotor semantics require approval. |
| [#457](https://github.com/payown/earshot/issues/457) | Search Everywhere remains applicable; scope and VoiceOver result navigation need review. |
| [#388](https://github.com/payown/earshot/issues/388) | Mock URL and much PlayerService coverage now exist; audio-session seam and first UI/integration smoke test remain autonomous test work. |

### Low or externally blocked

| Issue | Disposition |
| --- | --- |
| [#680](https://github.com/payown/earshot/issues/680) | External repository-plan decision: GitHub Pro or public-repository audit. Title corrected to `main`. |
| [#679](https://github.com/payown/earshot/issues/679) | Xcode 26.6 still has the documented StoreKit CLI defect; recheck on each Xcode update. |
| [#468](https://github.com/payown/earshot/issues/468) | Large local-audio/library project requiring model and product design. |
| [#467](https://github.com/payown/earshot/issues/467) | Blocked on hosted AASA/web pages and explicit associated-domains entitlement approval. |
| [#454](https://github.com/payown/earshot/issues/454) | Live Activities require capability/product approval and a separate extension surface. |
| [#453](https://github.com/payown/earshot/issues/453) | Download-complete notification remains a lower-priority opt-in UX feature. |

## Recommended execution order

1. Implement #709's non-UI measurement layer.
2. Extend #388's remaining non-UI test seam and integration coverage.
3. Collect normal-use evidence for #711 while builds are exercised.
4. Run controlled device fixtures for #696 and #801 when suitable backup test data/device state is available.
5. Batch product and VoiceOver-semantic decisions for #824, #834, #835, #719, #718, #717, #552, #465, and #457 before changing their UI.

No issue was closed merely because it was old. Open issues remain where acceptance
evidence, a product decision, protected-scope approval, hardware, an entitlement,
or an external service change is genuinely outstanding.
