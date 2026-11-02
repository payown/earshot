# StartTesting release-readiness audit — 1 November 2026

This is a working audit of the Earshot StartTesting project, not a claim that all open items block one App Store release. It was made from **both pages** of the 115 project items and the 22 project features. At the audit time, 22 bugs and 15 features were still open, in development, or in testing. Re-read the live records before closing anything; their IDs below are the durable references. Do not turn a simulator pass into a physical-device pass.

## Release gates and evidence rules

1. For each proposed fix, record the exact PR head, full CI result, merge commit, installed build, and device acceptance separately. Draft PRs are not included in build 297 unless explicitly stated below.
2. Test with VoiceOver on the actual iPhone and, for Mac-specific behavior, the Apple silicon Mac. Check spoken labels, values, actions, focus, latency, and the operation's durable result after relaunch. Preserve existing speech unless an intentional change is approved.
3. Use an isolated iCloud Drive test folder for destructive Listening Places tests. Capture a before/after copy or checksum of foreign device files and restore the ordinary selected folder after the test. Do not use a listener's only shared folder as the destructive fixture.
4. For storage-failure paths that cannot be safely induced on a production device, rely on injected-failure automated tests. On device, check the ordinary operation and the visible/spoken result; record the failure path as automated-only.
5. Run full CI on every final PR head. For this release, verify the final integrated build on device, then make a separate distribution decision. This document does not authorize TestFlight or App Store submission.

## Immediate build and integration state

- Build 1.2.5 (297) is available to the accepted internal TestFlight account. It includes the merged Listening Places byte-comparison guard (#1027), but the November 2 Mac test showed that it still overwrites a valid synthetic foreign file already at this Mac's device-file path. The isolated fixture changed hash after folder selection and the app reported a successful write. The ordinary iCloud test folder was restored. A follow-up identity check is being tested in a separate branch. The Mac folder-selection correction remains **draft PR #1035**; its final-head CI run 41391023255 passed. Verify the build's exact source revision before treating any later PR as installed.
- Draft PR #1036 reports bulk download clear/cancel failures and preserves a path after file removal fails. Nine selected simulator tests and full CI run 41392272203 passed on its earlier head. Head `eade3ff3` adds safe download diagnostics; 104 selected integrated simulator tests passed and fresh full CI run 41464234970 is queued. Physical VoiceOver checks remain.
- PR #1024 (download path reconciliation) remains open despite earlier iPhone checks on development build 293. Its current head `89d8ae93` passed full CI run 41393016055; review and merge remain.
- A local integration branch `codex/release-candidate-integration-20261102` at `cb11ddcc` combines #1024, #1035, #1036, #1038, #1039, and #1041 without merging them to `main`. The affected download, Listening Places, OPML, and feedback suites passed 170/170 simulator tests together before the logging-only follow-up. On the final integration head, download and synthetic-secret diagnostic suites passed 104/104. Workflow-dispatch full CI run 41464389573 is queued; the previous branch run was canceled before execution when the head changed. Draft #1042 was created later and is not on this integration branch. This branch has not been archived, installed, or distributed.
- An unrelated open documentation PR #1033 needs its own review. Its presence does not establish product acceptance.

## Proposed path to the next release candidate

1. **Finish data-safety integration.** Bring #1024 through fresh integrated-head CI and merge. Review #1036 after full CI, then merge if its failure reporting and partial-cleanup behavior are accepted. Do not treat either as a cure for the separately tracked cleanup-before-save risk.
2. **Resolve Listening Places reliability.** The build-297 foreign-file acceptance check failed on the physical Mac. Complete the identity guard, full CI, and a repeat check on a new integrated TestFlight build before accepting #1027. Review #1035 after its passing CI and the existing shared-folder/VoiceOver check. Decide whether the offline-timestamp issue must be fixed before broadening Listening Places availability; it can overwrite newer cross-app progress, and the historical timestamps cannot be reconstructed.
3. **Finish the smaller correctness changes.** #1038 (OPML result speech) and #1039 (chapter-sheet identity) are drafts with passing CI runs 41457594010 and 41393268579. Physical device checks remain. Keep their code and acceptance evidence separate from the Listening Places release decision.
4. **Review remaining exposure.** The broader synthetic-token logging audit and cleanup-before-save design are unfinished. Treat both as explicit risk decisions, with links to their StartTesting items and a tested mitigation or scoped deferral before an App Store candidate is called ready.
5. **Build one integrated candidate.** Confirm the final main commit, clean CI, version/build, changelog, installation and TestFlight access. Exercise the prioritized device checks below on that exact candidate. Earlier builds and local development builds do not substitute for final-candidate acceptance.

The feature requests for generated chapters and retroactive episode filtering have prerequisites and separate design decisions. The older features in Testing still need listener acceptance, but their outstanding checks should be scheduled without silently treating their old TestFlight availability as a new release gate or as a pass.

## First session when the Mac is unlocked

1. TestFlight showed Earshot **1.2.5 (297)** installed and opened it on the Mac. The in-app About screen also reported version **1.2.5**, build **297**.
2. The isolated iCloud Drive folder **Earshot Listening Places Foreign File Guard Test 297** contained a synthetic foreign device file. Selecting it on build 297 reported a successful write and changed the file's SHA-256 from `d7c712c201147eb5062b89f5ee212cfbac4ba97c93e5c43263c86263cafeac96` to `2e92fa133ad0a1068d5895b4cdcff82176ed4892ef7f9fd327883e8c83f83ee0`. This is a **failed physical acceptance check**, not a pass. Recreate the disposable fixture and repeat on a later build with the identity fix; observe VoiceOver speech then.
3. The selected folder was restored to **Earshot Listening Places iCloud Test 297** and the app showed it as selected with sharing on. After relaunch, the same selection and sharing state persisted, and status showed a later successful write. The disposable foreign-file fixture was recreated with synthetic contents for a later build; its current SHA-256 is `d13b42898e275a863a2300a5545c76f57b61e40099be5a7b6cb284fd5623b95d`.
4. Michael confirmed there is no existing iPhone-shared folder on this Mac. As an isolated substitute, I created **Earshot Listening Places Synthetic iPhone Test 297** in iCloud Drive with a valid synthetic iPhone-style device file. On physical Mac build 297, selecting that folder set the selected-folder label, kept sharing on, and reported a successful write. Earshot created this Mac's separate device file beside the synthetic file. A second **Write Now** updated the status. The synthetic file's SHA-256 remained `0cc3585d1522bbf006a69c4f5c964375b05aca9ffb7df70b8d8d3c7830e35313` throughout. I restored **Earshot Listening Places iCloud Test 297** and confirmed it was selected with sharing on. This passes the shared-layout and foreign-file-preservation checks for a normal foreign path, but does not establish real iPhone-to-Mac handoff or VoiceOver speech.
5. Build 297's Send Feedback switch still described an iOS version and device model. An unsent draft identified this machine as **Mac** and reported **macOS 27.0**, while the host reports **27.0.1**. The draft was canceled. On the final build containing #1035, check the revised opt-in hint/footer speech and repeat the unsent draft comparison; the patch mismatch remains a separate question.

The real iPhone-to-Mac handoff, step 5's fixed-build checks, and VoiceOver verification remain pending. The synthetic-folder result is an app result on build 297, but is not a real cross-device pass.

## Bug inventory and next action

- **Listening Places folder selection fails on Apple silicon Mac** (`3ccc95fe-4526-46cb-831f-d693b575674a`; Testing)
  - Apple silicon Listening Places folder picker. Draft #1035; fresh local/iCloud selection and relaunch passed on Mac; final-head CI passed. Build 297 also selected a synthetic iPhone-style iCloud folder, wrote its own separate device file, and left the synthetic file unchanged. Michael has no existing iPhone-shared folder on this Mac; test a real handoff when one is available, then verify VoiceOver and relaunch on the fixed build.
- **Listening Places can replace a changed or unrelated device file** (`6d33508d-7c3c-4221-91f0-1aaea16bfc4f`; In development)
  - Physical build-297 test failed: the app replaced a valid synthetic foreign file at its own device-file path on folder selection. Earlier #1027 compares observed bytes but did not validate the file's format, app marker, and device ID before accepting those bytes. Draft #1041 adds the identity check; 41 Listening Places service tests passed on a clean simulator and full CI is running. Repeat with the recreated synthetic fixture on an integrated build, then check VoiceOver status and file bytes.
- **Mac feedback metadata omits macOS patch version and uses iOS-specific opt-in wording** (`157e1399-850b-405c-9dbc-77302f1ed233`; In development)
  - #1035 changes Send Feedback hint/footer to platform-neutral wording with 11 focused tests. Physical build 297 baseline: the hint still says iOS, while an unsent draft correctly says `Device: Mac` and `macOS: 27.0`; the host reports 27.0.1. On a later build, inspect the revised opt-in speech and draft metadata. Find a supported accurate source before claiming patch-version resolution. Cancel drafts; do not send.
- **Download clear or cancel can report success after a persistence failure** (`cfde8bcb-d249-4dc6-9c98-f653159df3b3`; In development)
  - Draft #1036; 9 selected simulator tests and full CI run 41392272203 passed on the earlier head. Head `eade3ff3` adds safe download diagnostics; 104 selected integrated simulator tests passed and fresh full CI is queued. With VoiceOver, clear and cancel ordinary downloads, verify success counts and state after relaunch. Injected failure announcements are automated-only unless safely reproducible on device.
- **Download cleanup can remove audio before related changes are saved** (`bd1fa12c-ced4-42d9-a718-46d21750f044`; In development)
  - Cleanup-before-save risk spans Queue, Inbox, played-state and download ownership. The existing local draft is not integrated. Require a recoverable cross-store design, crash-boundary, shared-file, retry, and failure tests before merge. Then check ordinary download retention on device.
- **Listening Places can assign newer timestamps to older offline listening** (`8401d54f-a78e-41c5-a768-9ae6a6752f5e`; In development)
  - Listening Places offline changes can receive later export timestamps. Design durable event provenance and migration; test competing updates, reset, sharing off/on, and relaunch. Historical times cannot be reconstructed. Cross-app test with QUILL only after deterministic merge tests.
- **Network and artwork error logs may expose private URL tokens** (`cb8fea95-4e72-45dd-8a93-8a9ae1acd4dc`; In development)
  - #1013/#1014 sanitized several network, artwork and search logs. #1036 head `eade3ff3` also sanitizes remaining `DownloadManager` public error and title logs; fresh CI is pending. Draft #1042 head `ce1f2f0e` removes public title/error text from export and bookmark logs and marks feed/subscription podcast titles private; an iOS Simulator build passed and full CI is pending. The [diagnostic privacy audit](diagnostic-privacy-audit-2026-11-02.md) maps the remaining paths. Continue with **synthetic** URL tokens and error text; never put real tokens in logs or the issue.
- **Chapter sheet can show a stale list after switching episodes** (`9698f261-ece7-4cbe-85d8-e43e3ab836bc`; In development)
  - Draft #1039 makes the sheet use the player's current chapter result and guards old row actions. Generic simulator build and full CI run 41393268579 passed; physical VoiceOver check remains. Switch playback **while the sheet stays open**, then revisit; inspect focus and chapter selection. Prior check closed the sheet first.
- **OPML import failures need a clear spoken explanation** (`0e41be7b-39b4-4f2e-afd4-ec79b0c4676f`; In development)
  - Draft #1038 adds distinct spoken explanations for invalid XML, unresolved results and folder-save failure, with retained-file retry guidance. Its final head also removes literal inflection markup from plain speech; full CI run 41457594010 passed. On device use a disposable malformed OPML file and verify speech and retained import state.
- **Episode filters: durable history, undo, and mark-as-played outcome** (`b5e53934-a559-4ea7-93df-9fa43050bbb8`; Open)
  - Deferred episode-filter history/undo/mark-played design. Depends on version 1 real-feed usage and persistence measurements. Do not fold into release stabilization without the prerequisite evidence.
- **Episode filters: explicit apply-to-existing-episodes workflow** (`48c3d039-c17c-4f29-ab40-f181db9f3a66`; Open)
  - Explicit apply-filters-to-existing-episodes workflow. Depends on version 1 and a separate bounded, undoable design. Keep out of a stabilization patch.
- **Background download journal can lose events on storage errors** (`7bbcfeaf-989a-4d3a-860d-592a7cf8ae5e`; Testing)
  - Background download journal #1026 merged; full CI passed. On device, start a download, background/force close and reopen, confirm no event/state loss and playable file. Record any interruption scenario actually exercised.
- **Download cancel and immediate retry can affect the new attempt** (`e3f701de-93d5-4bcf-9342-aaf96f737383`; Testing)
  - Attempt ownership #1026 merged. On device cancel a download and immediately retry the same episode; ensure the new attempt completes and the old callback does not cancel or remove it. Repeat after relaunch.
- **Download path reconciliation can mistake an access error for a missing file** (`5e35bd88-3259-481f-9180-a8901a879122`; Testing)
  - #1024 is open; current head `89d8ae93` passed full CI run 41393016055, and ordinary offline/relaunch passed on build 293. Review and merge remain; protected-data or inconclusive access remains unverified.
- **Download recovery can erase an episode volume boost setting** (`abcc18b1-9f9a-4cf3-80b9-638f5b0a6552`; Testing)
  - Volume boost recovery #1020 merged and CI passed. Set a non-default episode boost, perform a normal download/recovery or app relaunch, verify value and audio behavior persist. Synthetic recovery tests remain the failure evidence.
- **Library reset can leave local files and iCloud out of sync after failure** (`0b1fe556-780b-4b48-9127-cefe63df7636`; Testing)
  - Library reset recovery #1028 merged and CI passed. Use a disposable library/device state to verify interrupted-reset recovery heading/focus and local/iCloud result. Never reset the only copy of personal data as a test.
- **Followed-podcast fetch failure can be treated as empty refresh** (`359b5abf-c9de-4863-8433-9285ff98f7dc`; Testing)
  - Followed-podcast fetch failure #1014 merged; injected fetch tests passed. On device verify ordinary empty and populated refresh speech; failure speech remains automated-only unless safely reproducible.
- **Personal Audio deletion can report success when saving failed** (`1c8f5aae-dce6-444d-8c52-509f0064eb2c`; Testing)
  - Personal Audio deletion failure #1016 merged and CI passed. Import a disposable file, delete it, inspect spoken outcome and absence after relaunch. Injected save-failure result is automated-only.
- **Damaged pending OPML import can prevent staging a replacement** (`79115438-7882-44cf-9689-ad7b77333fe5`; Testing)
  - Damaged pending OPML replacement #1016 merged and CI passed. Use disposable malformed/staged files to verify replacement, cancellation, confirmation and relaunch. Do not damage the user's real staged import.
- **Device acceptance: OPML import, folder, and duplicate subscriptions** (`419d2373-73ed-458c-b802-2d78170f475d`; Testing)
  - Requested phone acceptance: import a small OPML with an already-followed podcast and a folder, then import twice. Verify folder and no duplicate subscriptions.
- **Device acceptance: Personal Audio import, playback, and cancellation** (`fb83dc20-c435-4d5e-964d-fddb24c66891`; Testing)
  - Requested phone acceptance: import Personal Audio, play and resume, then cancel a second import if it runs long enough. Report cancellation as untested if it cannot be exercised.
- **Explain Listening Places versus iCloud Sync consistently** (`9e5852d4-8bb0-45bf-b2b0-6b1799502533`; Testing)
  - Listen to the VoiceOver explanation of Listening Places versus iCloud Sync on device; verify the distinction is understandable in settings and persists after relaunch. Prior launch of build 288 was not acceptance.

## Feature inventory and device acceptance

The following features are separate from release-blocking regressions unless their current implementation is unstable. Use the latest integrated build containing the feature and record the build number beside each result.

- **Customize player transport actions and increments** (`44edd5c8-2977-4029-8dfd-1dc5cd885c59`; In development)
  - Configurable player transport actions: check direct rewind/fast-forward increments, each button's configurable VoiceOver actions, order, labels, chapter/queue commands, large text and playback. Obtain CI and integration evidence first.
- **Generate chapter markers for episodes without publisher chapters** (`aabf63aa-4032-4766-a2ec-9a09411f5a1b`; Planning)
  - Generated chapter markers: measure chapter coverage, define language/device/cost/privacy and cancellation behavior before implementation.
- **Offer an option to keep finished episodes in the Queue** (`1f5ad0a4-fed6-46f5-b698-d8e7a7189489`; Testing)
  - Keep finished in Queue: enable, finish an episode, verify retained placement, replay, focus and relaunch; then disable and compare.
- **Add Move to Top and Move to Bottom actions across Queue grouping modes** (`ef1df45f-eff0-4fcc-a4e9-41d2d21441f5`; Testing)
  - Move to Top/Bottom across Queue grouping modes: test each mode, current playback, focus and relaunch.
- **Add Next Chapter and Previous Chapter Siri and Shortcuts actions** (`5599a486-2d5e-4559-9a8c-c2663b0a56d0`; Testing)
  - Invoke Next/Previous Chapter through Siri/Shortcuts on an episode with chapters and one without; confirm playback position and spoken result.
- **Move an episode directly to the top of its current Queue group** (`b8e096d7-e41f-45ed-9934-2f5897d96842`; Testing)
  - Move to top of current Queue group; verify it remains in the correct group and focus is stable.
- **Support VoiceOver pick-up and drop actions for arbitrary Queue reordering** (`67fc0742-af80-4ddb-a1fb-b2ad3b3ee2aa`; Testing)
  - VoiceOver pick-up/drop arbitrary Queue item, including across groups; check position, focus, responsiveness, playback completion and relaunch.
- **Add configurable dynamic-range compression and equalization** (`1f0a5c06-1e92-428f-af56-b0e614cd0624`; Testing)
  - Compare compression Off/strengths and EQ neutral/bands while listening; relaunch, seek, change speed/routes, background playback, listen for distortion and responsiveness.
- **Provide comprehensive playback Shortcuts and ready-to-use shortcut examples** (`5c360d17-0739-413c-a777-2a50ab28548e`; Testing)
  - Run a representative set of playback Shortcuts and examples, including error/no-current-episode cases; verify action output and VoiceOver.
- **Offer Add to Top placement when queuing an episode** (`e38a60ab-95f7-411a-ba1f-a812ecaee975`; Testing)
  - Add to top from Inbox, Library, Search, Downloads and a folder; verify Queue order and focus.
- **Offer oldest-to-newest ordering for the whole Queue** (`6a87ac6f-7d09-40fd-9bcc-db6c66cae6c9`; Testing)
  - Oldest-to-newest whole Queue: current playback, equal/missing dates, grouping transition and relaunch.
- **Add per-podcast Skip outro to finish before end ads** (`ac2b2e5d-c538-4471-9c85-0c2a5071726b`; Testing)
  - Skip outro: boundary completion once, Queue/folder/sleep/stop-after-current, seek/resume in final interval, Off, short/unknown duration, download, speed and background.
- **Allow larger VoiceOver playback-position seeking steps** (`95700a0a-2162-4d4b-bb61-2492a81880be`; Testing)
  - Larger VoiceOver position steps: change setting, seek forward/back, check spoken value, bounds, playback continuity and persistence.
- **Make marking podcast episodes unplayed easy to find** (`0974d59d-da27-4f37-8248-85a02177e2b4`; Testing)
  - Find and use mark-unplayed in podcast episode list; verify result, selection, focus and relaunch.
- **Select all or invert selected podcast episodes for batch actions** (`4bc62015-6d92-4f59-a1a1-07416880bd45`; Testing)
  - Select all beyond 100 rows, invert, deselect exceptions, batch mark played/unplayed, check filtered Inbox, cleanup, focus and responsiveness.

## Recording a physical result

For each item, add to StartTesting: build number and source revision if known; device/OS; exact steps; expected and observed result; VoiceOver speech/focus; whether the result persisted after relaunch; and which cases were **not** exercised. A passing ordinary path does not close an injected-failure issue by itself. If a check fails, save a sanitized reproduction and route it to the existing item or a distinct new defect. Close an item only after its fix is merged and the relevant acceptance is confirmed; record distribution separately.
