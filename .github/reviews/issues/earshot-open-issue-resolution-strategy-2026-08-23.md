# Earshot remaining-issue resolution strategy

> Refreshed 2026-08-23 after build 234 work, against `main` commit `1fdfc77`.
> Scope: the 11 issues open when this cycle began. All had zero reactions and no
> available GitHub Project metadata.

## Outcome

Three of the original 11 issues are complete, leaving eight open:

- #465 and #550 were implemented, tested, merged, and closed.
- #679 was already unquarantined in current code; plain Xcode 26.6 CLI and the
  required CI gate both ran its StoreKit suites successfully, so it was closed.
- #680 and #801 remain evidence/external-state issues rather than code defects.
- #570 and #571 require one shared audio-processing architecture plus physical
  listening and route-quality validation.
- #686, #467, and #454 require protected project/capability changes and external
  prerequisites.
- #468 is a separate local-library data and file-lifecycle project.

The previous `[Unreleased]` changelog was archived under 1.2.0, creating a fresh
TestFlight cycle. The new section now contains only the #465 and #550 work.

## Completed in this cycle

| Issue | Result | Verification |
| --- | --- | --- |
| [#465](https://github.com/payown/earshot/issues/465) | Podcast Quick Actions open the existing download-count, queue-age-limit, and per-podcast-speed editors and focus their native adjustable controls. No schema change. | 1,934 applicable tests passed locally; required CI passed; PR #894 merged. |
| [#550](https://github.com/payown/earshot/issues/550) | Queue options can save, replace, apply, and clear an on-demand lineup. Applying restores available unplayed episodes at the front, preserves all other Queue order, syncs stable identities through private iCloud, caps storage at 100 episodes, and announces exact counts. | 1,966 unit tests plus the UI smoke test passed locally; required CI passed; PR #895 merged. |
| [#679](https://github.com/payown/earshot/issues/679) | Confirmed stale and closed. Current workflow has no StoreKit skip flag and current tests have no skip guards. | All 12 StoreKit tests passed through plain Xcode 26.6 CLI; the required CI gate also passed with the suites enabled. |

## Remaining priority order

Scores combine current user value, implementation readiness, risk, and blocking
dependencies. Reaction score is zero for every remaining issue.

| Order | Issue | Score | Status and next safe action |
| ---: | --- | ---: | --- |
| 1 | [#686 iPad support](https://github.com/payown/earshot/issues/686) | 4 | High user reach, but intentionally gated on `TARGETED_DEVICE_FAMILY`, real-iPad VoiceOver/layout QA, all orientations, and App Store screenshots. Do not claim completion from simulator-only evidence. |
| 2 | [#571 volume boost](https://github.com/payown/earshot/issues/571) | 4 | Build only with #570’s shared processing pipeline. Requires a gain stage, limiter, route/interruption handling, persisted resolution policy, and device listening. |
| 3 | [#570 silence trimming](https://github.com/payown/earshot/issues/570) | 4 | Existing global key and podcast override are hooks, not an implementation. Spike `MTAudioProcessingTap`/audio-engine behavior first; verify time accounting and audible quality on physical routes. |
| 4 | [#468 local audio import](https://github.com/payown/earshot/issues/468) | 3 | Needs durable local identity, security-scoped import/copy policy, metadata/artwork parsing, deletion and backup behavior, playback integration, and a Library surface. Treat as its own architecture phase. |
| 5 | [#467 Universal Links](https://github.com/payown/earshot/issues/467) | 2 | Needs a chosen HTTPS share domain, hosted AASA file, associated-domains entitlement, stable episode URL contract, and fallback behavior. Domain and capability approval are prerequisites. |
| 6 | [#454 Live Activities](https://github.com/payown/earshot/issues/454) | 2 | Needs an ActivityKit extension/capability, privacy and stale-state policy, update throttling, Dynamic Island layouts, and device validation. Keep behind now-playing stability work. |
| 7 | [#801 migration margin](https://github.com/payown/earshot/issues/801) | 1 | Still applicable because installed V5/V6 stores may upgrade directly to V10. Mac-owned peaks are deterministic at 2.87×/3.02× versus the 4.5× gate; representative physical V6 high-water evidence remains missing. Never install a synthetic old store on Michael’s live phone. |
| 8 | [#680 branch protection](https://github.com/payown/earshot/issues/680) | 0 | Reconfirmed blocked: the repo is private and GitHub returns 403 for both `main` protection and rulesets. Completion requires GitHub Pro or a public-repository security/history audit and visibility change. |

## Recommended next execution batch

1. Obtain explicit protected-scope approval and access to a real iPad before #686.
2. Prototype one shared, disabled-by-default audio-processing pipeline for #570
   and #571. Merge neither audible feature until physical-device route, clipping,
   battery, interruption, and VoiceOver responsiveness tests pass.
3. Make the product choices that unblock #467: share domain and URL format. Then
   perform the entitlement and AASA work together so links never ship half-wired.
4. Write and approve #468’s local identity/file-lifecycle design before adding a
   schema version or import UI.
5. Leave #801 and #680 open until their external evidence/state changes; neither
   has an honest autonomous code-only completion path today.

## Device checklist for build 234

1. In a podcast’s Actions rotor, activate Change download count, Change queue age
   limit, and Edit per-podcast speed. Confirm each sheet opens and VoiceOver lands
   on the intended adjustable control.
2. Reorder several Queue episodes, choose Queue options > Save as lineup, change
   the Queue, then Apply saved lineup. Saved episodes should move to the front in
   saved order and unrelated episodes should remain after them.
3. Mark one saved episode played or remove its podcast, then apply again. Confirm
   the exact skipped count is announced and the Queue remains usable.
4. Replace and clear the lineup. Clearing the saved lineup must not clear the
   current Queue.
5. If a second device is available, let private-iCloud sync finish and confirm the
   saved lineup appears there without changing that device’s Queue until Apply is
   activated.
