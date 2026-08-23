# Earshot open-issue resolution strategy

> Refreshed 2026-08-23 after shipping build 232 from `main` commit `67d35d9`.
> Scope: all 11 open Earshot issues. All have zero GitHub reactions. Project
> board status is unknown because the current token does not expose Projects.

## Outcome

The remaining backlog contains no known release-blocking playback, download, or
data-loss defect. Two medium features are bounded enough to implement now. Four
issues require an explicit capability, repository-plan, hardware, or hosting
decision. Three are substantial audio/library projects. Two are evidence tasks
whose production behavior is already conservative.

## Priority order

| Order | Issue | Score | Confidence | Current-code finding | Action |
| ---: | --- | ---: | --- | --- | --- |
| 1 | [#465 Podcast Quick Actions](https://github.com/payown/earshot/issues/465) | 0 | **High** | Queue age and speed editors already exist; the download count is the existing global per-podcast-count setting. | Add configurable actions that open the existing editors without a schema change. |
| 2 | [#550 Morning lineup](https://github.com/payown/earshot/issues/550) | 0 | **Medium** | Queue ordering and accessible move actions exist; no saved lineup exists. | Implement the previously approved first slice: a manually saved and applied lineup, not scheduling. |
| 3 | [#686 iPad support](https://github.com/payown/earshot/issues/686) | 0 | **High** | The app remains intentionally iPhone-only in `project.yml`. | Prepare simulator/layout evidence; changing device family and shipping screenshots needs iPad QA and capability approval. |
| 4 | [#679 StoreKit CI](https://github.com/payown/earshot/issues/679) | 1 | **High** | Xcode 26.6 is still required and the repository documents the same `SKInternalErrorDomain Code=3` failure. | Re-run the quarantined suites only after a newer Xcode is installed; keep physical Sandbox verification. |
| 5 | [#801 migration margin](https://github.com/payown/earshot/issues/801) | 1 | **High** | V5/V6 remain supported sources for V10. Deterministic peaks are 2.87x and 3.02x against a 4.5x gate. | Keep as low-priority physical V6 assurance; do not alter Michael's live store. |
| 6 | [#680 branch protection](https://github.com/payown/earshot/issues/680) | 1 | **High** | The repository is still private on the free plan; rules remain unenforced. | Requires GitHub Pro or a public-repository history/secrets audit. |
| 7 | [#571 volume boost](https://github.com/payown/earshot/issues/571) | 0 | **High** | Real gain needs a DSP path and limiter; the existing Voice Enhance feature is different. | Architecture/device-listening project, paired with #570. |
| 8 | [#570 silence trimming](https://github.com/payown/earshot/issues/570) | 0 | **High** | No safe live DSP graph exists; prior research found real-time tap and streaming risks. | Start only with an approved audio-engine spike and device quality plan. |
| 9 | [#468 local audio](https://github.com/payown/earshot/issues/468) | 0 | **High** | No local-media identity/import model exists. | Separate schema, Files import, lifecycle, backup, and library architecture project. |
| 10 | [#467 Universal Links](https://github.com/payown/earshot/issues/467) | 0 | **High** | No AASA/episode web surface or Associated Domains entitlement is present. | Blocked on hosted web content and explicit entitlement approval. |
| 11 | [#454 Live Activities](https://github.com/payown/earshot/issues/454) | 0 | **High** | No ActivityKit extension or capability exists. | Defer until capability/product approval after core playback work. |

## Immediate execution

- [x] Reset `[Unreleased]` after build 232 while preserving its entries under
  the 1.2.0 release heading.
- [ ] Implement and test #465 in a small VoiceOver-reviewable pull request.
- [ ] Implement the manual saved-lineup slice for #550 in a separate pull request.
- [ ] Re-run the #679 suites when the installed Xcode changes from 26.6.
- [ ] Retain #801 until a safe representative physical V6 fixture is available.

## Blocked decisions

- [ ] #686: approve iPad device-family changes only when a real-iPad VoiceOver
  and orientation test pass can accompany them.
- [ ] #680: choose GitHub Pro or authorize the audit required before going public.
- [ ] #467 and #454: approve their signing/capability work only after the web or
  product prerequisites exist.
- [ ] #570 and #571: approve a dedicated DSP spike with device listening tests.
- [ ] #468: approve a local-media identity and persistence design before schema work.

## Notes

No issue should be closed merely for age. Completion requires merged code and
tests, conclusive evidence, or a deliberate not-planned product decision.
