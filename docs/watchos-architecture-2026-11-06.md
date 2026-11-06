# Earshot for Apple Watch: audit and implementation plan

**Status:** Architecture proposed; implementation awaits Michael's approval under `CLAUDE.md` and `.claude/rules/phase-progression.md`. No target, capability, entitlement, signing, purchase UI, or frozen schema has been changed.

**Branch/worktree:** `feature/watchos-architecture` at `/Users/michaelbabcock/code/earshot-watchos`, based on `main` at `360d95c1`.

## Toolchain and deployment decision

The installed Xcode is 27.2 (27B52), matching the installed Apple-authored skills exported from Xcode 27.2. XcodeGen is 2.46.0. The watchOS SDK is 27.2. The repository asks for Xcode 27.0 (27A266a), so release/CI reproducibility with that exact toolchain remains a gate. The SDK permits watchOS 9.0 through 27.2; its platform version map pairs iOS 18.0 with watchOS 11.0. **Proposed minimum: watchOS 11.0**, aligned with the existing iOS 18.0 minimum. Newer APIs need availability checks. Do not use the SDK default of 27.2.

Use an independent, single-target watchOS companion app with its own bundle ID and `WKRunsIndependentlyOfCompanionApp`. Apple documents independent installation and operation, but warns that Watch Connectivity cannot be the primary data source. The watch must fetch feeds and media itself. A WidgetKit extension is separate from the watch app target.

## Repository audit

| Area | Actual implementation | Watch decision |
| --- | --- | --- |
| App lifecycle | `EarshotApp.swift` creates `AppRuntime` with phone services, UIKit, notifications, migration recovery and CloudKit startup. | New watch lifecycle and dependency graph. Do not compile this root into watchOS. |
| Models/store | `Podcast`, `Episode`, `QueueItem`, `Bookmark`, folders and local state use SwiftData. `EarshotSchema.swift` has frozen V1–V14 generations. `StoreMigration.swift` and `ModelContainerFactory.swift` protect existing phone data. | Separate watch-local store and schema. Never open/copy the phone SQLite store or edit a frozen snapshot. Migration and recovery tests required for each shipped watch schema change. |
| Cloud sync | `CloudProjection.swift` mirrors compact subscription, episode-state, queue, setting, bookmark, session and folder projections with per-device IDs, timestamps, tombstones and deterministic reconciliation. The full episode catalog remains local because a 232,921-episode CloudKit bootstrap failed. Release enables the projection; Debug is local-only. | Reuse **data contract and pure reconciliation rules**, after a cross-platform extraction and real two-device migration tests. Do not point the current phone coordinator at a watch store or deploy new CloudKit record types. Preserve local-only downloads, paths, refresh state and entitlement caches. |
| Feeds/network | `RSSParser.swift` is Foundation/XMLParser based. `FeedService.swift`, `HTTPClient.swift`, `RetryPolicy.swift`, `SecureURL.swift` and `EarshotURLSession.swift` are potential portable seams. `FeedRefreshActor.swift` mixes parsing with phone-store ingestion and policy. | Extract portable parser/client/identity code into a shared source set or module. Write watch ingestion with bounded refresh and watch-local storage. Preserve HTTPS upgrade and existing cleartext media policy; review ATS parity before enabling HTTP feeds/media. |
| Playback | `PlaybackLogic.swift`, chapter navigation/parsing, sleep logic and stall rules are mostly pure. `PlayerService.swift` is ~4,200 lines and imports UIKit/MediaPlayer, phone audio processing and phone store assumptions. | Share pure rules only. Build a watch `AVPlayer` service, watch audio session, Now Playing/remote commands and interruption/route handling. Audit each MediaPlayer symbol in the watch SDK. Omit unsupported DSP with a documented setting fallback. |
| Downloads | `DownloadManager.swift` uses a process-wide iOS background URLSession, `LocalEpisodeState`, journal, composite feed URL/GUID identity and phone Documents path. | New watch download actor and local file index. Use direct URLSession downloads, temporary file move, validation, cancellation and recovery. `transferFile` is an optional accelerator; direct download must work when phone absent. Background behavior needs hardware proof. |
| Queue/inbox/folders/bookmarks | Repositories and views query phone `@Model` types; queue mutation journal and compact projection already encode offline edits. Inbox query avoids whole-library faults. Folder sync has cycle repair. | Reuse policies and stable natural keys, not phone UI/repositories wholesale. Watch queries must be bounded and remain local when disconnected. Queue conflict UI must surface a real unresolved conflict, never silently overwrite. |
| Monetization | `EntitlementStore` derives Plus from verified StoreKit 2 `Transaction.currentEntitlements`; `PodcastCapPolicy` enforces 10 free subscriptions. | Reuse product IDs and pure entitlement/cap rules. Read verified entitlements on watch with a local cached result for offline use; test universal purchase and expiry. No new products or purchase UI in this plan. |
| Accessibility | Phone rows use configurable Quick Actions and a measured iOS rotor-order compensation; focus/announcements are handled in each screen. | Preserve terminology and configured order where synced. Verify watchOS rotor ordering on hardware before applying the iOS reversal. Direct Play, stable focus anchors, adjustable seek/speed, sparse announcements and VoiceOver review are release gates. |
| App Intents | Current intents bridge to the phone runtime and phone SwiftData. | New watch intents use watch services and stable episode natural keys. Do not reuse phone bridge. Check watchOS availability and retriable `perform()` semantics. |
| Tests | Extensive iOS unit and UI tests exist, including feed, playback, queue, downloads, CloudKit projection and entitlement tests. | Add watch unit, UI and deterministic protocol/connectivity tests; run existing iOS suite for regression. Simulator cannot validate radio, Bluetooth, background audio or handoff. |

Relevant references inspected: `docs/icloud-sync-v1.1-plan.md`, `docs/sync-a2-identity.md`, `docs/cloudkit-tombstone-retention-plan.md`, `docs/swiftui-accessibility-audit.md`, `.claude/rules/database-migrations.md`. `docs/perf-baseline.md` named by `AGENTS.md` is absent in this checkout; use current performance plans and device measurements before setting watch budgets. `CLAUDE.md` has stale Xcode 26.6 and iPhone-only prose; `project.yml` and current source are authoritative.

## Architecture contract

1. **Identity:** canonical feed URL plus episode GUID is the cross-device episode key. A watch-local row owns its file path, download state and refresh metadata. No `PersistentIdentifier` crosses devices.
2. **Local-first:** watch SwiftData holds subscribed feed metadata, bounded episode catalog, queue, inbox, bookmarks, progress, settings and durable pending mutations. Read and write locally without waiting for phone or CloudKit. Feed requests and streams use watch networking.
3. **Cloud ownership:** compact projection is the durable cross-device user-state channel once watch compatibility and existing schema are verified. Neither device mirrors media files or full feed catalogs. Existing per-device contribution/tombstone rules remain the starting point; add deterministic tests for watch/phone concurrent queue reorder, remove, progress reset, mark played/unplayed and subscription edits before enabling watch writes.
4. **Connectivity:** version every Watch Connectivity envelope, include event UUID, origin device, logical revision/time and acknowledgment status. `updateApplicationContext` carries replaceable latest playback/availability snapshot; `sendMessage` with reply is only for immediate control and handoff prepare/commit while reachable; `transferUserInfo` carries durable small edit/ack events; `transferFile` carries optional audio with validated identity and checksum. Deduplicate on receipt, persist unacknowledged commands, reject stale snapshots, reconcile on activation and reconnect. Never infer success from `isReachable` alone.
5. **Playback ownership:** explicit `watch`, `phone` and `none` state. A control command shows pending then acknowledged result or failure. Handoff is prepare (receiver resolves URL/local file, route and session), ready acknowledgment, commit/start receiver, then stop source after receiver confirms actual playback. If confirmation fails, source continues and the UI explains the failure. A transaction ID makes retries safe. Test timeouts and crash recovery to avoid both devices playing indefinitely.
6. **Watch playback:** `AVAudioSession` category `.playback`, route-sharing policy `.longFormAudio`, asynchronous activation, then `AVPlayer` start. Apple says watchOS needs a Bluetooth route for long-form audio and may present a route picker. Provide a direct route-status label and never claim playback began before actual time control/route confirmation. Background audio mode is required.
7. **Power/storage:** fetch on entry, pull-to-refresh or bounded scheduled refresh; use HTTP validators. Save progress on meaningful intervals/background/stop, not each tick. Keep download concurrency and storage limits conservative; pause/retry with readable status. Widgets use snapshots/timelines and event-based reloads within WidgetKit budgets, not continuous updates.

## Reviewable implementation phases

Each phase gets a small PR to `main`, assigned to `@payown`, with non-generated changes under 1,500 lines. Each is built and tested, includes VoiceOver review for UI, and stays unmerged until Michael approves a physical-device test build.

1. **Foundation and project generation.** Approve watch bundle ID, watch-specific Info.plist/background audio, CloudKit/App Groups if needed, independent installation flag and target packaging. Add watch app/unit/UI test targets in `project.yml`; run `xcodegen generate`; prove empty-library independent launch and iOS regression. No phone signing changes.
2. **Portable core and watch library.** Extract feed parser/network, natural keys, cap rules and select playback/queue policies. Add watch-local persistence/recovery, direct subscribe/search/refresh, library, inbox, folders and offline metadata. Validate migration and 10-subscription cap before watch CloudKit writes.
3. **Independent player.** Watch AVPlayer/audio session, stream/local playback, controls, chapters, speed, sleep timer, route/interruption/stall recovery and system Now Playing. Validate on watch hardware with VoiceOver.
4. **Watch downloads and bookmarks.** Direct downloads, verified atomic file placement, cancellation/recovery/storage reporting, offline playback, bookmark and progress persistence. Optional phone `transferFile` follows direct-download success.
5. **Cross-device sync and control.** Cloud projection integration with existing schema, two-way WC protocol, remote control and transactional handoff. Build deterministic offline conflict tests and physical loss/reconnect tests.
6. **Widgets, intents and release hardening.** WidgetKit complication/Smart Stack extension, deep links, watch App Intents, migration/entitlement audit, broad iPhone regression, performance and VoiceOver device gate, TestFlight candidate.

## Approval gates and unknowns

- **Approval now:** `CLAUDE.md` requires an outline and confirmation before code; its phase-progression rule requires confirmation before a new phase. Phase 1 changes the project and introduces watch capabilities. Michael must approve the target identifier and watch background-audio mode, and whether the existing CloudKit container entitlement may be added to the watch target. Existing iOS signing/entitlements/capabilities remain untouched.
- **CloudKit:** Verify that the current production compact projection schema and per-device contribution model can safely accept watch records. Never initialize/deploy a new production CloudKit schema or change entitlements silently. The existing tombstone-retention follow-up remains unresolved.
- **StoreKit:** Apple documents universal purchases for companion watch/iOS apps, but the current product configuration and `Transaction.currentEntitlements` must be tested on a paired device and an independently installed watch. Purchase UI/restoration changes require separate approval.
- **Audio/ATS:** Verify watch SDK availability for MediaPlayer remote commands, AVPlayer media formats, background URLSession behavior and direct HTTP media policy. Do not copy iOS ATS exception without review.
- **Distribution:** Current `tool/swiftui-testflight.sh` assumes one app target. Audit and extend it only after watch packaging/signing are approved. No release or upload is authorized by this plan.

## Build and validation commands

After Phase 1 approval and code changes, from the linked worktree:

```bash
xcodegen generate
xcodebuild -list -project Earshot.xcodeproj
xcodebuild build -project Earshot.xcodeproj -scheme EarshotWatch -configuration Debug -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild test -project Earshot.xcodeproj -scheme EarshotWatch -configuration Debug -destination 'platform=watchOS Simulator,name=<installed watch simulator>' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild test -project Earshot.xcodeproj -scheme Earshot -configuration Debug -destination 'platform=iOS Simulator,name=<installed iPhone simulator>' -skip-testing:EarshotTests/PaywallViewModelTests -skip-testing:EarshotTests/ProductCatalogServiceTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

The watch scheme and target above are **planned, not yet present**. Choose installed simulator names with `xcrun simctl list devices available`. For hardware builds, use command-line automatic signing and `-allowProvisioningUpdates DEVELOPMENT_TEAM=72PH974742`; do not change signing files.

## Michael's VoiceOver hardware checklist (release gate)

Use a paired physical Apple Watch and iPhone, with VoiceOver enabled on both. Record watch model/watchOS, iPhone/iOS, Earshot build, network and audio route for each run. A second run must install the watch app without installing the iPhone app.

1. Install the watch build alone. Disconnect iPhone Bluetooth or turn the phone off. Launch Earshot, follow one feed using watch input, browse its episodes, stream one over Wi-Fi and another over cellular. Confirm every screen has a useful empty/error state and no phone spinner.
2. Download an episode, wait for a spoken completion/status, enter Airplane Mode, relaunch Earshot and play the file. Cancel another download, then try under low storage. Verify no partial file appears as playable and deletion returns VoiceOver focus to a stable row/heading.
3. On Now Playing, double-tap Play once and hear audio; pause, skip, restart, adjust speed and scrub with VoiceOver swipe-up/down. Read elapsed/remaining time and chapter; move between chapters. Check sleep timer, route label, system Now Playing and Bluetooth headphone removal. Confirm interruption resumes only when appropriate.
4. In Inbox, use actions rotor to Play, Play Next, Play Later and Mark Played/Unplayed. Confirm configured action names/order and that direct Play is dependable. Reorder/remove Queue items and verify focus remains in Queue. Test large text, high contrast, Reduce Motion, button shapes and different watch sizes.
5. With both devices installed, start on watch, switch to phone, then reverse. Confirm destination audio starts before source stops and the UI announces the actual owner. Turn off Bluetooth/out-of-range during a remote command; verify an explicit failure and no false success. Make conflicting queue/progress/bookmark edits offline on each, reconnect, and inspect the resolved result.
6. Add each complication/Smart Stack widget, activate its deep link, and verify the intended screen. Check stale-content wording. Speak each supported shortcut. Verify Plus state and the 10-feed free limit on an independently installed watch without buying anything.

Record each step as pass/fail with the spoken phrase and where focus lands. Simulator results are supplementary; background audio, Bluetooth, cellular, Watch Connectivity and handoff need physical hardware. Run the repository's `earshot-accessibility` review on every SwiftUI PR before proposing merge.

## Apple references checked

- [Independent watchOS apps](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps)
- [Setting up a watchOS project](https://developer.apple.com/documentation/watchos-apps/setting-up-a-watchos-project)
- [Playing background audio](https://developer.apple.com/documentation/watchkit/playing-background-audio)
- [Enabling background sessions](https://developer.apple.com/documentation/watchkit/enabling-background-sessions)
- [Watch Connectivity transfers](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity)
- [WidgetKit complications](https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications)
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [App Intents](https://developer.apple.com/documentation/appintents)
