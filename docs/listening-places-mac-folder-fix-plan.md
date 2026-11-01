# Listening Places on Apple silicon Mac: investigation and fix plan

**Status:** Mac reproduction and bookmark failure identified; correction awaiting physical Mac validation
**Feedback record:** StartTesting `3ccc95fe-4526-46cb-831f-d693b575674a`  
**Reported build:** App Store 1.2.4 (274), Mac running macOS 27.2  
**Review base:** `origin/main` at `1f0a5fb0`, Earshot 1.2.5 (284)  
**User report:** Selecting the same iCloud folder used on iPhone does not appear to set it on an M3 iMac. Listening Places says, “Could not write listening places. The file ‘Earshot’ couldn’t be opened.” Feedback metadata incorrectly says `iPad8,6` and “iOS 27.2.”

## Progress on November 1

- `0494fc84` changes the opt-in feedback block to label the iOS-on-Mac runtime as Mac/macOS, while keeping iPhone formatting. The actual macOS version still needs a live Mac app check.
- `f2954f8f` prevents a superseded folder-selection failure from overwriting the current status and adds privacy-safe stage/error-code logging for folder preparation, bookmark resolution, directory coordination/creation, README creation, restore, and replacement. It does not change the file-provider access sequence or claim to fix the reported iCloud failure.
- `cb79997a` coordinates first README creation in the iCloud File Provider directory. This removes an uncoordinated write from folder preparation; a real Mac iCloud test is still required to establish whether it contributes to the reported failure.
- The focused iPhone 17 Pro simulator run passed 52 Listening Places and feedback tests with no failures or skips. A Mac-designed-for-iPhone test destination is available, but an unsigned test install was rejected by code-signature verification. Do not replace the installed production/development Earshot app with a test runner just to run this suite.
- A separate focused Listening Places test run and a generic iOS Release build passed after the README change. The Mac currently has Earshot 1.2.5 (285); TestFlight 1.2.5 (296) is active in both tester groups, both of which enable Apple silicon Mac testing. Build 296 is a comparison baseline and does not include these worktree changes.
- The opened 1.2.5 (285) process is an Xcode temporary app copy rather than `/Applications/Earshot.app`. Its Listening Places screen says “Selected folder, None” and “Choose a folder to begin.” This is a useful state check but does not reproduce the affected selection. Physical Mac iCloud reproduction and the underlying provider error remain the next gate.
- TestFlight 1.2.5 (296) reproduced the report on this Apple silicon Mac with a fresh local Downloads folder: Selected folder stayed None and the status named the chosen folder as unable to open. The macOS unified log at the failure emitted `kCFURLBookmarkCreationMinimalBookmarkMask cannot be used with scoped bookmarks`, followed by Earshot's `NSCocoaErrorDomain 256` failure. This identifies bookmark creation, before directory or device-file I/O, as the failure in this reproduction. It also makes an iCloud-specific provider fault unnecessary to explain Marco's report. The user's exact iCloud folder has not been tested.
- A code change now chooses a full bookmark in the iOS-on-Mac runtime while retaining the minimal bookmark on iPhone/iPad. Apple documents that `withSecurityScope` and `minimalBookmark` cannot be combined. The Mac picker URL evidently carries a scope even when Earshot does not explicitly request the former flag. This is the leading correction, not yet validated in a running fixed Mac app.
- Commit `bc41c429` contains that correction and a regression test for the platform-dependent bookmark options. The focused Listening Places suite passed 42/42 on iPhone 17 Pro iOS 26.3.1 simulator. A signed Mac-designed-for-iPad Debug build compiled. Its manually assembled temporary Mac wrapper launched a process but did not show an accessible window; this cannot be counted as a physical fix test. The Mac unit-test attempt was blocked by a local UI-test-runner provisioning profile that lacks this Mac, unrelated to the product failure.

## Outcome and boundaries

Make a user-selected iCloud folder usable for Listening Places in Earshot's iOS app running on Apple silicon Mac. Preserve existing files, local listening state, and the last working folder when a new selection fails. Correct feedback metadata so it identifies the Mac and macOS. Verify on a real Mac with the affected type of folder before TestFlight distribution.

This plan covers defects directly encountered in folder selection, bookmark persistence, provider access, directory preparation, device-file write/recovery, and feedback metadata. The separate Listening Places timestamp/provenance work and unrelated sync or playback changes remain separately tracked. Do not edit issue #395 areas, `SettingsReset`, accessibility semantics, signing, entitlements, capabilities, or purchase UI without the repository-required explicit sign-off. If evidence makes one of those changes necessary, prepare the concrete patch and review evidence before requesting sign-off.

## What the source currently proves

1. `ListeningPlacesSettingsView` uses SwiftUI `.fileImporter` for `.folder`. Its completion starts `ListeningPlacesService.chooseFolder` in a task. The status row uses the same generic “Could not write listening places” prefix for selection, restore, and write failures. The report alone therefore does **not** locate the failing operation.
2. In released build 296, `chooseFolder` starts access on the picker URL, creates a `.minimalBookmark`, and calls `ListeningPlacesFileTransport.prepareFolder` **before** committing the new bookmark, folder name, and enabled state. The current worktree chooses a full bookmark on Mac. A preparation failure keeps the previous selection. After committing, it calls `restoreExistingAndWrite`; a later read/write failure can leave the new folder selected but display the same failure prefix. Check the actual Selected folder row to distinguish these cases.
3. `prepareFolder` resolves the bookmark, starts scoped access, creates `Listening Places/devices`, and writes or updates `README.txt`. Directory creation coordinates each existing parent with `.forMerging`; first creation may coordinate the selected parent named “Earshot.” A failure naming that folder is consistent with this step, but not proof of it.
4. `startAccessingSecurityScopedResource()` may return `false` on both the picker and resolved URLs. The code proceeds without distinguishing denied scope from provider or filesystem errors. It does balance every successful start with a stop.
5. `ensureSubdirectory` uses `fileExists` to decide whether a path is absent, then retries coordinated creation four times. A provider that cannot materialize an item may look absent at this check. `prepareLayout` writes a missing README outside explicit file coordination, and a README failure can reject selection even when the device directory is usable. Existing legacy README update errors are deliberately best effort.
6. The initial device-file read is coordinated. The code treats a specific missing-file Cocoa code as absence; a provider-specific missing-item or materialization error may instead abort restore. The current tests prove local temporary-directory cases, including existing layout creation, README preservation, guarded replacement/removal, and several async ownership races. They do not prove real macOS iCloud provider behavior.
7. `chooseFolder` catches errors without checking whether the selection was superseded during its `await`. A delayed failure from an older selection could overwrite the visible status for a newer selection. This is a code review finding to prove with a deterministic test before changing it.
8. `AppSettingsStore.setRawValue` and `setBool` catch and log persistence errors. `chooseFolder` assumes all three settings writes succeeded and can display an active folder that may not survive relaunch. This is a related durability risk, not evidence of Marco's failure. Avoid changing the generic settings API unless a narrowly scoped solution cannot work.
9. On a library with no exportable listening state, snapshot preparation can return no device-file bytes and status can become “Ready” after layout preparation alone. A writable README is not necessarily proof that `devices/<device-id>.json` can be written. Decide whether setup success requires a device-file probe or whether the UI must distinguish folder preparation from a verified snapshot write; avoid creating an unsafe probe in a shared folder.
10. `SendFeedbackView` labels `UIDevice.current.systemVersion` as iOS and uses `uname`'s machine string as the device. In the reported Mac environment this yielded `iPad8,6`. Apple documents `ProcessInfo.isiOSAppOnMac` for recognizing an iPhone/iPad app on Mac. We can report “Mac” and “macOS” reliably; the exact commercial Mac model is not guaranteed by that API.

## Leading hypotheses, in test order

| Hypothesis | Evidence for it | Discriminator |
| --- | --- | --- |
| Bookmark or security scope does not grant write access in the Mac runtime | The selection is external to the app container and scope failures are not distinguished | Record picker-scope and resolved-scope boolean results, stale flag, operation, and sanitized NSError domain/code; compare direct picker URL with the immediately resolved bookmark |
| iCloud File Provider cannot open/materialize the selected `Earshot` parent for coordinated creation | The error names the selected parent; directory creation coordinates that parent | Compare fresh local, fresh iCloud, existing iCloud, and materialized/offline folders; locate the exact `NSFileCoordinator` call and its error |
| Directory exists but README or missing device-file read fails | All are performed during setup/restore and share the same status prefix | Stage-specific diagnostics and a read-only inspection of the selected layout |
| Existing `Listening Places` or `devices` item conflicts with the expected directory | `isDirectory` and creation can encounter an existing file or provider alias | Inspect item types and permissions without deleting or renaming anything |
| Repeated selection and async status race obscure a successful or newer choice | `chooseFolder` catch lacks a generation check | Controlled suspended transport test with two selections and a late first failure |

Do not attribute the issue to Mac entitlement or Apple behavior until a real Mac trace supports it. Apple’s iOS directory-picker guidance explicitly describes folder bookmarks, scoped access, and coordinated I/O; the current `.minimalBookmark` choice follows that guidance. See [Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories), [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator), and [Running your iOS apps in macOS](https://developer.apple.com/documentation/apple-silicon/running-your-ios-apps-in-macos).

## Execution sequence

### 1. Establish a reliable Mac reproduction

- Start from a linked worktree and feature branch based on current `main`. Preserve the main checkout and its documentation. Record the exact source commit and built version.
- Confirm the delivery mode in App Store Connect and on the Mac: iPhone/iPad app running on Mac versus Catalyst/native Mac build. Record actual macOS version and Earshot version/build separately from the current feedback block.
- Reproduce with the affected Mac App Store 1.2.4 (274) if available, then with a signed development build from current `main`. Do not replace or modify the reporter's shared folder merely to inspect it; use a copy or an agreed test folder first.
- Capture before/after **Selected folder** value, share-toggle state, status text, folder contents, and whether a `devices/<Mac device ID>.json` file appears. The error string alone cannot tell whether preparation or the later write failed.
- Add temporary, privacy-safe stage diagnostics for picker URL access, bookmark creation/resolution and staleness, resolved URL access, directory check/coordination/create, README operation, device-file read, and device-file replace. Record `NSError` domain/code and underlying domain/code, not raw paths, bookmarks, episode names, or file contents. Keep a bounded timeout in manual provider tests so a stalled provider is visible as a stall.

### 2. Isolate provider, permission, and layout behavior

Test the same build with these destinations on the Mac:

| Destination | Purpose |
| --- | --- |
| Fresh writable local folder chosen through the picker | Baseline picker/bookmark/coordinator behavior on Mac |
| Fresh iCloud Drive folder, fully downloaded | iCloud creation path without old layout |
| Existing iCloud folder with `Listening Places/devices` from iPhone | Reported shared-layout path; verify Mac uses its own file |
| Existing iCloud folder with `Listening Places` but no `devices` | Intermediate directory creation |
| Existing folder with an edited README | Verify user content is preserved |
| Offline or evicted iCloud item, then available again | Provider materialization and retry messaging |
| Revoked Files and Folders permission, then reselected | Access-denied and recovery behavior |
| A directory slot occupied by a regular file | Actionable conflict without destructive repair |

For each, record whether failure occurs at initial selection, after first snapshot write, after app relaunch, or after Mac restart. Compare a new folder with the exact affected folder only after non-destructive tests. Validate a real listening-state change to force a JSON write; an empty library can otherwise give a misleading “Ready.”

### 3. Implement the narrowest evidence-based correction

- If scope is denied, stop before filesystem I/O and return an actionable permission/reselect error. Keep successful scope starts balanced. Verify whether the picker URL or resolved bookmark differs on Mac before changing bookmark creation. Do not add macOS-only bookmark flags to an iOS app based on speculation.
- If parent coordination fails, adjust the coordinated directory creation sequence to the provider's demonstrated requirements. Preserve one-level-at-a-time creation and avoid silently treating an inaccessible directory as absent. Do not delete an existing item to make creation succeed.
- If README creation is the only blocker, decide whether it should be best effort while preserving all user-edited README content. A failed informational write must not be mistaken for successful device-file write access.
- If the first coordinated read treats a missing file as an error, distinguish true absence from permission/provider failures using the actual Cocoa/provider errors, not a blanket `try?`. Preserve the compare-before-replace and compare-before-remove protections merged in PR #1027.
- Make folder selection state and failure status own the current generation. A failed replacement must leave the last working bookmark and its file intact; an older failed selection must not overwrite a newer successful selection. Verify storage success on relaunch and surface a failure if the selected bookmark cannot be persisted.
- Keep disk work off the main actor so File Provider latency does not stall VoiceOver. Preserve current labels, values, traits, rotor actions, announcements, and focus byte-for-byte unless Michael approves a specific semantics change. Any new actionable status copy needs that review.
- Update feedback construction to use `ProcessInfo.isiOSAppOnMac` to label this runtime “Mac” and the OS “macOS”; validate the version source on a real Mac. Continue the current iPhone reporting format on iPhone. Prefer a generic Mac label to an unreliable model identifier and retain the opt-in, anonymous system-info behavior.

### 4. Focused automated verification

Add tests that prove behavior rather than mirror method calls:

- A suspended first selection fails after a second succeeds; the second folder and status remain current.
- Failed new selection retains the previous working folder, bookmark, enabled state, and ability to write; no file in either folder is removed.
- Revoked/failed scope, stale bookmark, absent target, occupied directory, README failure, and coordinator error produce the right state without reporting success. Inject errors only at the observed failure boundary.
- Relaunch restores a persisted Mac-selected bookmark. A failed settings save cannot present a durable success.
- Initial empty-library setup and first meaningful snapshot have truthful status; actual device JSON is checked when claiming a successful write.
- File-provider retry and cancellation do not block the main actor or spin. Existing changed/foreign/malformed device files and edited READMEs remain untouched.
- Feedback tests cover iPhone and Mac platform labels/version formatting and confirm the block contains no private path, host name, serial number, or account information.

Run the focused Listening Places and feedback suites, then the normal full CI suite. Use the current repository's StoreKit skip policy for local tests. Run a clean Release build with Xcode 27.0 / Swift 6.4 / XcodeGen 2.46.0. Only regenerate the Xcode project if `project.yml` changes; do not edit signing or capabilities as part of this plan.

### 5. Physical Mac and accessibility acceptance

- Use a real Apple silicon Mac running macOS 27.2 or the closest supported available version. Validate both fresh and existing iCloud folders, the affected provider scenario, relaunch, offline/online recovery, and separate iPhone/Mac JSON files.
- With VoiceOver, navigate the full Settings → Listening Places path; choose/rechoose a folder, inspect Selected folder and Status, toggle sharing, use Write Now, and return from picker/alert/confirmation. Confirm no UI hang during provider access and that focus and spoken semantics match the approved behavior.
- While the iPhone continues writing its own file, verify its bytes are not overwritten or removed by the Mac. Check the Mac file's format, identifier, label privacy setting, and changes after a real listening action. Do not infer cross-device import: Listening Places is still export-only.
- Confirm the feedback form on Mac says Mac and macOS with the correct version, and on iPhone keeps the correct iPhone/iOS data. The reporter's exact M3 iMac model is optional and should not be claimed unless a supported, reliable source is proven.
- Record the actual Mac and iPhone results, failures, and remaining provider limitations in StartTesting. Keep the item in testing until the required physical checks pass.

### 6. Delivery and communication

- Keep code PRs small and reviewable, target `main`, assign `@payown`, and stay below 1,500 non-generated changed lines per PR. Split a feedback metadata correction from the folder fix if it makes review or risk clearer. Link each PR and CI run in StartTesting.
- After Michael approves the tested fix for distribution, follow `docs/kashe.md` for the next TestFlight build. Put **What to try first** and the Kashe story at the end of the notes, use the actual build number, and verify processing, both tester groups, and active beta availability. An upload alone does not establish tester access.
- Ask the reporter to retry the same iCloud folder in TestFlight and confirm selection, a successful write, and persistence after relaunch. Record his result as listener confirmation, separate from team Mac tests.
- Ship the accepted fix in the next App Store update; verify the production build includes the merged commits before closing the issue. Do not describe an untested upload or a merged PR as a resolved user experience.

## Exit criteria

The root cause is supported by a captured operation and error code; the fix passes focused and full automated tests; real Mac iCloud and VoiceOver checks pass; the iPhone file and local listening state remain safe; Mac feedback metadata is accurate at the platform level; and the TestFlight build is demonstrably available to the intended testers. Keep unresolved provider-specific or timestamp/provenance work in its separate records rather than declaring it solved here.
