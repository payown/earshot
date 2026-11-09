# Earshot project state — November 9, 2026

This is a dated integration and test handoff. Check current GitHub and App Store Connect state before treating build or branch status as current.

## Integrated source

- Source integration reached protected `main` at `d3822620`: iPhone Duo (#1052–#1053), native iPad (#1054), Watch widgets and initial handoff (#1055), Watch offline library and CloudKit (#1056), reviewed Watch playback and guarded phone control (#1057), paired playback/queue work (#1058), and build 313 crash isolation plus build 314 handoff/Magic Tap quality work (#1059). The historical documentation and private build 315 version bump are in this follow-up PR.
- #1057 merged at `8015eefe`; required Swift CI run 42535412408 and post-merge main run 42536901147 each passed 2,739 unit tests and 41 UI tests. The run uses four narrow exclusions detailed below.
- #1058 merged at `4423bbd2`; required Swift CI run 42536960663 passed 2,743 unit tests and 41 UI tests. Copilot did not post a review on #1058; the source was inspected for state freshness, matching episode guards, audible phone start before Watch pause, and rollback. No GitHub approval was marked on Michael's behalf.
- #1059 merged at `d3822620`; required Swift CI run 42560269002 passed 2,749 unit tests (34 scheme skips) and 41 UI tests (8 scheme skips) with zero failures. On its final reviewed source, Watch simulator tests passed 46 unit and 5 UI tests. Codex review fixed a stale paired-queue tombstone overriding a newer item and a late refresh reporting success after timeout; the immediate paired snapshot path remains disabled. No Copilot or human GitHub approval was claimed.

## Test and release limits

- Build 313 `cfb08daa` reproduced two failing methods on unchanged source in `/tmp/earshot313-baseline-targeted.log`: `CloudProjectionCoordinatorTests.testBurstOfRemoteImportNotificationsCoalescesAndStopsCleanly` (three `0 != 1` assertions) and `InterruptedLibraryResetRuntimeTests.testSameAccountRecoveryCompletesBeforeNormalLaunch` (four recovery assertions). See [the 314 quality report](watchos-playback-quality-314.md) for the exact command and assertions. These are baseline failures, not diagnosed or accepted behavior. The CI workflow excludes only these two methods plus the two StoreKit simulator suites tracked in #679. CloudKit and library-reset behavior still need hardware verification.
- The iPadOS 26.0 Search switch UI automation SIGABRT was reproduced on unchanged iPad source `f34d2897`; iPadOS 26.5/27.2 tests passed. The physical-device impact is unknown. Start Testing issue `3ac299f7-774b-45c8-8ca4-18b9e0bcb2f3` remains open.
- Current active Public Testers build was 1.2.6 (305) at the last check. Build 311 was historically public, then withdrawn after the Watch-open iPhone crash. App Store Connect build 314 is `VALID` and in the Internal Testing Group, but en-US What to Test is empty. The next private candidate remains on version 1.2.6 at Michael's request. App Store Connect reported 315 as the next available build number on November 9; recheck before archiving. No public distribution is authorized.
- Michael is considering version 1.3 for a later App Store release once the combined work is accepted. Do not treat that proposed version as an instruction to bump the private candidate or submit it publicly.
- Kashe history is canonical in [kashe.md](kashe.md), including restored Chapters 113–119 and the prepared Chapter 120 for private build 315. The Chapter 120 text exactly matches `docs/testflight/build-315-notes.txt` and is 2,150 characters. The chapter and tester notes are not shipped until the private build is actually uploaded with those notes.

## Physical acceptance and bug-fix entry

1. Update iPhone and Watch in place. Repeatedly open Watch with iPhone foreground/background; confirm no phone crash and data retained.
2. Compare final iPhone and Watch positions and spoken words on transfers at normal and 1.5x. Try VoiceOver Magic Tap on Watch Home, Now Playing and iPhone Control. Verify exactly one action and correct target.
3. Test direct/offline Watch downloads, Bluetooth and interruptions, CloudKit progress and queue sync while immediate paired snapshots remain disabled, plus iPad/Duo navigation, focus, dynamic type and multiwindow behavior.
4. Verify StoreKit purchases with Sandbox on a physical device. Characterize the iPadOS 26.0 Search crash on supported hardware before any public beta decision.

Four Watch bug reports are code-fixed but await physical acceptance: overlapping play `ba3909fa-e801-4194-8122-8658ace15e4b`, shortcut routing `a8c109f1-8d7c-421c-a724-a98958a07ea7`, paused state speech `05e165bc-ddcb-4574-b332-2ac8099ca10b`, and early phone acknowledgement `02c682f3-79bc-44e9-a1c2-0ebc84e9e5cd`. Other unfinished Start Testing items, including download cleanup durability, broader token redaction, Listening Places timestamps, Mac patch metadata and customizable transport, are separate from this 314 integration and should be triaged after the merged baseline.

The last complete Start Testing inventory contained 40 active items: 21 bugs, 16 features, two acceptance tasks and one improvement. The authenticated endpoint answered read-only organization and item requests, while this Codex session did not expose the native Start Testing MCP tools. Treat that as a session visibility limit, not evidence that the service is down. Recheck item status before triage. The original Watch PRs #1046–#1051 and Duo PR #1044 remain open as historical or superseded branches; do not merge them blindly over the integration PRs.

Older draft #1037 is a dated build-297 Start Testing audit with still-unfinished reliability items, not a current 315 release decision. The build-295 change inventory from #1033 is preserved in the historical documentation slice. Continue triaging the older audit's open items separately after device acceptance of the combined candidate.

This host currently has Xcode 27.2 (27B52), Apple Swift 6.4.2, and XcodeGen 2.46.0. Repository guidance calls for Xcode 27.0 (27A266a), so record this difference when interpreting simulator or CI results.

Create the next bug-fix worktree from the final protected `main` commit after the historical documentation/private build PR merge. Do not use the older `codex/bugfix-baseline-20261108` branch or the root checkout as the starting tree.
