# StartTesting release-readiness audit — 1 November 2026

This is a working audit of the Earshot StartTesting project, not a claim that all open items block one App Store release. It was made from **both pages** of the 115 project items and the 22 project features. At the audit time, 22 bugs and 15 features were still open, in development, or in testing. Re-read the live records before closing anything; their IDs below are the durable references. Do not turn a simulator pass into a physical-device pass.

## Release gates and evidence rules

1. For each proposed fix, record the exact PR head, full CI result, merge commit, installed build, and device acceptance separately. Draft PRs are not included in build 297 unless explicitly stated below.
2. Test with VoiceOver on the actual iPhone and, for Mac-specific behavior, the Apple silicon Mac. Check spoken labels, values, actions, focus, latency, and the operation's durable result after relaunch. Preserve existing speech unless an intentional change is approved.
3. Use an isolated iCloud Drive test folder for destructive Listening Places tests. Capture a before/after copy or checksum of foreign device files and restore the ordinary selected folder after the test. Do not use a listener's only shared folder as the destructive fixture.
4. For storage-failure paths that cannot be safely induced on a production device, rely on injected-failure automated tests. On device, check the ordinary operation and the visible/spoken result; record the failure path as automated-only.
5. Run full CI on every final PR head. For this release, verify the final integrated build on device, then make a separate distribution decision. This document does not authorize TestFlight or App Store submission.

## Immediate build and integration state

- Build 1.2.5 (297) is available to the accepted internal TestFlight account. It includes the merged Listening Places foreign-file guard (#1027). Folder selection passed on the physical Mac with build 297, while the source correction remains **draft PR #1035**. Final-head CI run 41391023255 passed. Verify the build's exact source revision before treating every subsequent PR change as installed; the later feedback wording commit was tested locally, not in build 297.
- Draft PR #1036 reports bulk download clear/cancel failures and preserves a path after file removal fails. Nine selected simulator tests passed; full CI and physical VoiceOver checks are pending.
- PR #1024 (download path reconciliation) remains open despite earlier iPhone checks on development build 293. Its prior head `5dfd39f2` passed full CI. The branch was updated onto current main as `89d8ae93`; fresh integrated-head CI and merge are required.
- An unrelated open documentation PR #1033 needs its own review. Its presence does not establish product acceptance.

## Proposed path to the next release candidate

1. **Finish data-safety integration.** Bring #1024 through fresh integrated-head CI and merge. Review #1036 after full CI, then merge if its failure reporting and partial-cleanup behavior are accepted. Do not treat either as a cure for the separately tracked cleanup-before-save risk.
2. **Resolve Listening Places reliability.** Review and merge #1035 after its passing CI and the existing shared-folder/VoiceOver check. Complete build-297 foreign-file guard acceptance using the isolated fixture. Decide whether the offline-timestamp issue must be fixed before broadening Listening Places availability; it can overwrite newer cross-app progress, and the historical timestamps cannot be reconstructed.
3. **Finish the smaller correctness changes.** #1038 (OPML result speech) and #1039 (chapter-sheet identity) are drafts pending CI and device checks. Keep their code and acceptance evidence separate from the Listening Places release decision.
4. **Review remaining exposure.** The broader synthetic-token logging audit and cleanup-before-save design are unfinished. Treat both as explicit risk decisions, with links to their StartTesting items and a tested mitigation or scoped deferral before an App Store candidate is called ready.
5. **Build one integrated candidate.** Confirm the final main commit, clean CI, version/build, changelog, installation and TestFlight access. Exercise the prioritized device checks below on that exact candidate. Earlier builds and local development builds do not substitute for final-candidate acceptance.

The feature requests for generated chapters and retroactive episode filtering have prerequisites and separate design decisions. The older features in Testing still need listener acceptance, but their outstanding checks should be scheduled without silently treating their old TestFlight availability as a new release gate or as a pass.

## Bug inventory and next action

| StartTesting ID | Status at audit | Evidence and next verification |
| --- | --- | --- |
| `3ccc95fe-4526-46cb-831f-d693b575674a` | Testing | Apple silicon Listening Places folder picker. Draft #1035; fresh local/iCloud selection and relaunch passed on Mac; final-head CI passed. Test an **existing iPhone-shared** folder with VoiceOver, verify a newly written device file and relaunch. |
| `6d33508d-7c3c-4221-91f0-1aaea16bfc4f` | Testing | Foreign Listening Places device-file guard merged in #1027 and included in 297. Select the prepared isolated iCloud test folder, verify refusal and byte-for-byte unchanged foreign file, then restore the ordinary folder. Test VoiceOver status. |
| `157e1399-850b-405c-9dbc-77302f1ed233` | In development | #1035 changes Send Feedback hint/footer to platform-neutral wording with 11 focused tests. On Mac and iPhone, inspect the opt-in speech and draft metadata. Mac runtime reported 27.0 while host reported 27.0.1; find a supported accurate source before claiming patch-version resolution. Cancel drafts; do not send. |
| `cfde8bcb-d249-4dc6-9c98-f653159df3b3` | In development | Draft #1036; 9 selected simulator tests passed. Review final-head CI. With VoiceOver, clear and cancel ordinary downloads, verify success counts and state after relaunch. Injected failure announcements are automated-only unless safely reproducible on device. |
| `bd1fa12c-ced4-42d9-a718-46d21750f044` | In development | Cleanup-before-save risk spans Queue, Inbox, played-state and download ownership. The existing local draft is not integrated. Require a recoverable cross-store design, crash-boundary, shared-file, retry, and failure tests before merge. Then check ordinary download retention on device. |
| `8401d54f-a78e-41c5-a768-9ae6a6752f5e` | In development | Listening Places offline changes can receive later export timestamps. Design durable event provenance and migration; test competing updates, reset, sharing off/on, and relaunch. Historical times cannot be reconstructed. Cross-app test with QUILL only after deterministic merge tests. |
| `cb8fea95-4e72-45dd-8a93-8a9ae1acd4dc` | In development | #1013/#1014 sanitized several network, artwork and search logs. Audit remaining diagnostic paths with **synthetic** URL tokens and error text; never put real tokens in logs or the issue. |
| `9698f261-ece7-4cbe-85d8-e43e3ab836bc` | In development | Draft #1039 makes the sheet use the player's current chapter result and guards old row actions. Generic simulator build passed; full CI and physical VoiceOver check remain. Switch playback **while the sheet stays open**, then revisit; inspect focus and chapter selection. Prior check closed the sheet first. |
| `0e41be7b-39b4-4f2e-afd4-ec79b0c4676f` | In development | Draft #1038 adds distinct spoken explanations for invalid XML, unresolved results and folder-save failure, with retained-file retry guidance. Focused suite and CI are pending; on device use a disposable malformed OPML file and verify speech and retained import state. |
| `b5e53934-a559-4ea7-93df-9fa43050bbb8` | Open | Deferred episode-filter history/undo/mark-played design. Depends on version 1 real-feed usage and persistence measurements. Do not fold into release stabilization without the prerequisite evidence. |
| `48c3d039-c17c-4f29-ab40-f181db9f3a66` | Open | Explicit apply-filters-to-existing-episodes workflow. Depends on version 1 and a separate bounded, undoable design. Keep out of a stabilization patch. |
| `7bbcfeaf-989a-4d3a-860d-592a7cf8ae5e` | Testing | Background download journal #1026 merged; full CI passed. On device, start a download, background/force close and reopen, confirm no event/state loss and playable file. Record any interruption scenario actually exercised. |
| `e3f701de-93d5-4bcf-9342-aaf96f737383` | Testing | Attempt ownership #1026 merged. On device cancel a download and immediately retry the same episode; ensure the new attempt completes and the old callback does not cancel or remove it. Repeat after relaunch. |
| `5e35bd88-3259-481f-9180-a8901a879122` | Testing | #1024 is open; prior head `5dfd39f2` passed full CI and ordinary offline/relaunch passed on build 293. After branch update to `89d8ae93`, require fresh current-head CI and merge; protected-data or inconclusive access remains unverified. |
| `abcc18b1-9f9a-4cf3-80b9-638f5b0a6552` | Testing | Volume boost recovery #1020 merged and CI passed. Set a non-default episode boost, perform a normal download/recovery or app relaunch, verify value and audio behavior persist. Synthetic recovery tests remain the failure evidence. |
| `0b1fe556-780b-4b48-9127-cefe63df7636` | Testing | Library reset recovery #1028 merged and CI passed. Use a disposable library/device state to verify interrupted-reset recovery heading/focus and local/iCloud result. Never reset the only copy of personal data as a test. |
| `359b5abf-c9de-4863-8433-9285ff98f7dc` | Testing | Followed-podcast fetch failure #1014 merged; injected fetch tests passed. On device verify ordinary empty and populated refresh speech; failure speech remains automated-only unless safely reproducible. |
| `1c8f5aae-dce6-444d-8c52-509f0064eb2c` | Testing | Personal Audio deletion failure #1016 merged and CI passed. Import a disposable file, delete it, inspect spoken outcome and absence after relaunch. Injected save-failure result is automated-only. |
| `79115438-7882-44cf-9689-ad7b77333fe5` | Testing | Damaged pending OPML replacement #1016 merged and CI passed. Use disposable malformed/staged files to verify replacement, cancellation, confirmation and relaunch. Do not damage the user's real staged import. |
| `419d2373-73ed-458c-b802-2d78170f475d` | Testing | Requested phone acceptance: import a small OPML with an already-followed podcast and a folder, then import twice. Verify folder and no duplicate subscriptions. |
| `fb83dc20-c435-4d5e-964d-fddb24c66891` | Testing | Requested phone acceptance: import Personal Audio, play and resume, then cancel a second import if it runs long enough. Report cancellation as untested if it cannot be exercised. |
| `9e5852d4-8bb0-45bf-b2b0-6b1799502533` | Testing | Listen to the VoiceOver explanation of Listening Places versus iCloud Sync on device; verify the distinction is understandable in settings and persists after relaunch. Prior launch of build 288 was not acceptance. |

## Feature inventory and device acceptance

The following features are separate from release-blocking regressions unless their current implementation is unstable. Use the latest integrated build containing the feature and record the build number beside each result.

| StartTesting ID | Status at audit | Physical check or next design step |
| --- | --- | --- |
| `44edd5c8-2977-4029-8dfd-1dc5cd885c59` | In development | Configurable player transport actions: check direct rewind/fast-forward increments, each button's configurable VoiceOver actions, order, labels, chapter/queue commands, large text and playback. Obtain CI and integration evidence first. |
| `aabf63aa-4032-4766-a2ec-9a09411f5a1b` | Planning | Generated chapter markers: measure chapter coverage, define language/device/cost/privacy and cancellation behavior before implementation. |
| `1f5ad0a4-fed6-46f5-b698-d8e7a7189489` | Testing | Keep finished in Queue: enable, finish an episode, verify retained placement, replay, focus and relaunch; then disable and compare. |
| `ef1df45f-eff0-4fcc-a4e9-41d2d21441f5` | Testing | Move to Top/Bottom across Queue grouping modes: test each mode, current playback, focus and relaunch. |
| `5599a486-2d5e-4559-9a8c-c2663b0a56d0` | Testing | Invoke Next/Previous Chapter through Siri/Shortcuts on an episode with chapters and one without; confirm playback position and spoken result. |
| `b8e096d7-e41f-45ed-9934-2f5897d96842` | Testing | Move to top of current Queue group; verify it remains in the correct group and focus is stable. |
| `67fc0742-af80-4ddb-a1fb-b2ad3b3ee2aa` | Testing | VoiceOver pick-up/drop arbitrary Queue item, including across groups; check position, focus, responsiveness, playback completion and relaunch. |
| `1f0a5c06-1e92-428f-af56-b0e614cd0624` | Testing | Compare compression Off/strengths and EQ neutral/bands while listening; relaunch, seek, change speed/routes, background playback, listen for distortion and responsiveness. |
| `5c360d17-0739-413c-a777-2a50ab28548e` | Testing | Run a representative set of playback Shortcuts and examples, including error/no-current-episode cases; verify action output and VoiceOver. |
| `e38a60ab-95f7-411a-ba1f-a812ecaee975` | Testing | Add to top from Inbox, Library, Search, Downloads and a folder; verify Queue order and focus. |
| `6a87ac6f-7d09-40fd-9bcc-db6c66cae6c9` | Testing | Oldest-to-newest whole Queue: current playback, equal/missing dates, grouping transition and relaunch. |
| `ac2b2e5d-c538-4471-9c85-0c2a5071726b` | Testing | Skip outro: boundary completion once, Queue/folder/sleep/stop-after-current, seek/resume in final interval, Off, short/unknown duration, download, speed and background. |
| `95700a0a-2162-4d4b-bb61-2492a81880be` | Testing | Larger VoiceOver position steps: change setting, seek forward/back, check spoken value, bounds, playback continuity and persistence. |
| `0974d59d-da27-4f37-8248-85a02177e2b4` | Testing | Find and use mark-unplayed in podcast episode list; verify result, selection, focus and relaunch. |
| `4bc62015-6d92-4f59-a1a1-07416880bd45` | Testing | Select all beyond 100 rows, invert, deselect exceptions, batch mark played/unplayed, check filtered Inbox, cleanup, focus and responsiveness. |

## Recording a physical result

For each item, add to StartTesting: build number and source revision if known; device/OS; exact steps; expected and observed result; VoiceOver speech/focus; whether the result persisted after relaunch; and which cases were **not** exercised. A passing ordinary path does not close an injected-failure issue by itself. If a check fails, save a sanitized reproduction and route it to the existing item or a distinct new defect. Close an item only after its fix is merged and the relevant acceptance is confirmed; record distribution separately.
