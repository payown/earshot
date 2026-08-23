# Earshot open-issue resolution strategy

> Generated 2026-08-23 against build 220 / `main` commit `768ceef`.
> Scope: all 25 open Earshot issues. GitHub reactions are zero on every issue.
> Project-board status is unknown because the current token lacks `read:project`.

## Outcome

Build 220 launched successfully on Michael's iPhone. The current issue backlog is
not 25 unimplemented defects:

- three issues are closure candidates based on code, tests, and physical evidence;
- one migration issue remains technically applicable but should be narrowed and
  lowered in priority;
- four issues are active evidence or externally blocked work;
- eleven are bounded product/VoiceOver decisions followed by implementation;
- six are larger post-launch platform, audio, hardware, or architecture projects.

## Immediate device regression checklist

Run these on build 220 with VoiceOver. They cover the playback fix and the areas
changed in builds 215 through 220 without requiring destructive data changes.

1. **Near-end skip:** play an episode with at least two minutes remaining. Seek to
   about 95%, then press Skip Forward repeatedly. Position must move forward or
   complete; it must never bounce back to the same position.
2. **Queue completion:** put two episodes in Queue. Finish the first naturally.
   Confirm it leaves Inbox/Queue as played and the second starts according to the
   existing Continue After Episode setting.
3. **Position durability:** pause mid-episode, background Earshot, reopen it, and
   confirm the same episode and position return.
4. **Large-library VoiceOver:** swipe through about ten rows each in Library,
   Inbox, Queue, and Downloads. Report repeatable pauses, garbling, lost focus, or
   unexpected focus jumps.
5. **Audio routes:** while playing, connect or disconnect Bluetooth/AirPods and
   perform Play/Pause and Skip Forward. Playback must keep the expected route and
   command behavior.
6. **Search smoke:** search within Inbox, Queue, and Downloads, then cancel search.
   The full list and usable focus should return.

Do not factory-reset, erase app data, import a destructive migration fixture, or
change signing/capabilities for this checklist.

## Closure candidates

| Issue | Score | Confidence | Current evidence | Required user decision |
| --- | ---: | --- | --- | --- |
| [#690](https://github.com/payown/earshot/issues/690) | 1 | **High** | The requested URLCache teardown ordering exists. A fresh focused run passed all 20 ArtworkCache/SettingsStore tests, including teardown, directory removal, and reconstruction, with no Cache.db unlink violation. | Approve closing as completed. |
| [#696](https://github.com/payown/earshot/issues/696) | 2 | **High** | Physical 1,184-feed import profiling reduced the acute merge spike from an extrapolated ~1.7 GB to 6.6 MB. Build 220 now launches with Michael's 1,085-subscription library. | If current VoiceOver navigation is responsive, close as completed. |
| [#711](https://github.com/payown/earshot/issues/711) | 2 | **High** | Repeated physical snapshots remain small. Build 220 measured an 8 KB mirrored WAL and 1.38 MB local WAL, both far below the 32 MB investigation threshold. No checkpoint policy is justified by evidence. | If the four-tab VoiceOver pass is responsive, close with “no maintenance needed.” |

## Migration decision: #801

[#801](https://github.com/payown/earshot/issues/801) is not obsolete merely
because the destination schema is V10. Production still explicitly supports V5
and V6 source stores upgrading to V10, and the same 4.5× free-space gate runs
before that migration.

The issue is overstated as a high-priority current defect:

- Mac attributed measurements were deterministic at ~2.87× for V5 and ~3.02×
  for V6, below the 4.5× gate;
- a real V5-to-V10 physical upgrade succeeded;
- only a representative physical V6 high-water measurement remains unproven;
- an already-V10 phone cannot exercise this path.

Recommendation: retain it as low-priority migration assurance, retitle it to
“Validate the supported V5/V6-to-V10 migration storage margin on device,” and
remove `priority: high`. Do not manufacture or install a V6 store on Michael's
live phone.

## Evidence work still open

| Issue | Score | Confidence | Code reality and next action |
| --- | ---: | --- | --- |
| [#709](https://github.com/payown/earshot/issues/709) | 2 | **High** | Measurement is implemented. The first physical build-220 refresh sampled 3,103 episodes: 113 HTTP and 2,990 HTTPS (3.64% cleartext). ATS removal now would break real media. Next: test HTTPS substitution for those enclosures before designing a warning. |
| [#679](https://github.com/payown/earshot/issues/679) | 0 | **High** | Still valid. Under Xcode 26.6 both StoreKit suites retain the documented `SKInternalErrorDomain Code=3` runner failure and remain quarantined. Recheck only with a newer Xcode. |
| [#680](https://github.com/payown/earshot/issues/680) | 0 | **High** | Still externally blocked. GitHub currently returns 403 for both `main` protection and rulesets: upgrade to Pro or make the repository public. |

## Product and VoiceOver decision batch

These issues are not already implemented. They become bounded work after the
listed decision is approved. Their current priority score is zero; the order
below reflects daily-use value rather than age or reaction count.

| Order | Issue | Confidence | What already exists | Decision needed |
| ---: | --- | --- | --- | --- |
| 1 | [#457](https://github.com/payown/earshot/issues/457) | **High** | Inbox, Queue, Downloads, and Library search are implemented. | Narrow the issue to search within one podcast by episode title and description; approve the new `.searchable` VoiceOver surface. |
| 2 | [#552](https://github.com/payown/earshot/issues/552) | **High** | Shared rows already show and speak total duration before playback and time remaining in progress. | Decide whether in-progress rows should speak both remaining and total duration. Recommended: “20 minutes left, 30 minutes total.” |
| 3 | [#719](https://github.com/payown/earshot/issues/719) | **High** | Auto-download works, including new Inbox episodes, but the copy only says “Auto-download recent.” | Recommended: preserve behavior and clarify “per podcast” plus Inbox/Queue inclusion; avoid a migration or new scope setting. |
| 4 | [#717](https://github.com/payown/earshot/issues/717) | **High** | Transcript parsing/viewing and standard sharing infrastructure exist; transcript export does not. | Recommended: export from viewer and episode actions, include timestamps and a simple podcast/episode/date heading, no YAML front matter. |
| 5 | [#835](https://github.com/payown/earshot/issues/835) | **High** | Idempotent per-episode download and bounded batch patterns exist; no Download All command exists. | Recommended scope: current filtered tab contents, exact count confirmation, bounded enrollment, one final announcement. |
| 6 | [#718](https://github.com/payown/earshot/issues/718) | **High** | Natural completion and queue continuation are implemented; player auto-dismiss is not. | Recommended: global default-off setting; dismiss only when playback actually stops at end of queue, not during auto-advance. |
| 7 | [#824](https://github.com/payown/earshot/issues/824) | **High** | Local `inboxDismissed` state and whole-Inbox clearing exist; no single-row dismissal action or projection field exists. | Approve “Remove from Inbox” as separate from played state and last-write-wins conflict behavior. Requires two-device verification. |
| 8 | [#834](https://github.com/payown/earshot/issues/834) | **High** | Quick Actions can be reordered; omitted actions are currently restored automatically. | Approve Enabled/Available lists, minimum one enabled action, and default policy for newly introduced actions. |
| 9 | [#465](https://github.com/payown/earshot/issues/465) | **High** | Podcast Quick Actions cover detail, notifications, auto-queue, Inbox scope, folders, share, and unfollow. | Decide whether download count, queue age, and speed actions open existing editors or adjust values inline. |
| 10 | [#453](https://github.com/payown/earshot/issues/453) | **High** | Durable background download completion events exist; new-episode notifications exist. No download-complete notification exists. | Decide opt-in/default behavior and whether foreground completions should notify. |
| 11 | [#550](https://github.com/payown/earshot/issues/550) | **High** | Queue ordering and accessible move actions exist. | Choose saved queue template versus scheduled recurring lineup. Recommended first slice: manually applied saved template. |

## Larger or prerequisite-bound projects

| Issue | Confidence | Disposition |
| --- | --- | --- |
| [#551](https://github.com/payown/earshot/issues/551) | **High** | No App Intents dependency exists. Approve command vocabulary and interval limits before adding the new system surface. |
| [#570](https://github.com/payown/earshot/issues/570) | **High** | Settings/model hooks exist but no DSP. Pair with #571 after an audio-processing architecture and device-quality spike. |
| [#571](https://github.com/payown/earshot/issues/571) | **High** | Resolution logic exists but no gain/limiter DSP. Pair with #570. |
| [#686](https://github.com/payown/earshot/issues/686) | **High** | App is intentionally iPhone-only. Requires real iPad VoiceOver/layout QA, screenshots, orientations, and device-family approval. |
| [#467](https://github.com/payown/earshot/issues/467) | **High** | `onOpenURL` handles imports only. Requires hosted AASA content and associated-domains entitlement approval. |
| [#468](https://github.com/payown/earshot/issues/468) | **High** | No local-audio model/import path exists. Treat as a separate library architecture project. |
| [#454](https://github.com/payown/earshot/issues/454) | **High** | No ActivityKit target or capability exists. Treat as a post-now-playing stability feature with explicit capability approval. |

## Recommended execution sequence

1. Get Michael's build-220 VoiceOver and near-end playback result.
2. With confirmation, close #690, #696, and #711; narrow and lower #801.
3. Implement the first approved daily-use batch: #457, #552, #719, and #717.
4. Implement the bounded action batch: #835, #718, #824, and #834, preserving
   approved spoken semantics and testing on device after each small build.
5. Then address #465, #453, and the smallest approved #550 slice.
6. Keep #709 instrumented; do not remove ATS while 113 sampled episodes remain
   cleartext.
7. Schedule #551, #570/#571, #686, #467, #468, and #454 only when their
   hardware, capability, hosting, or architecture prerequisites are available.

