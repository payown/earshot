# Earshot Watch implementation progress

Build **1.2.6 (315)** is now available to the authorized Internal Testing
Group with Chapter 120 notes. See [the distribution record](testflight/build-315-internal.md)
for signed IPA, CI, group and remaining device-acceptance evidence. The dated
source and build 309–314 history below is retained unchanged.

## Source integration update, 2026-11-09

The dated build 309/310 notes below are retained as development history. The current
main integration sequence now includes Duo (#1052–#1053), native iPad (#1054),
Watch widgets and first handoff (#1055), offline library and CloudKit
reconciliation (#1056), playback and reviewed recovery fixes (#1057), paired
playback and Queue (#1058), and build 313/314 crash isolation, handoff alignment,
and Magic Tap (#1059).
The newest currently active public TestFlight build is 1.2.6 (305); an uploaded
internal 314 build does not make these source merges a distributed release.
Physical Watch, CloudKit, handoff position, VoiceOver Magic Tap, iPad and Duo
acceptance remain open. Immediate paired Queue snapshots stay disabled in the
later 313/314 safety path. Michael authorized a private internal candidate
after source integration and validation. At this source checkpoint, that new
candidate had not been uploaded or publicly distributed.

Historical 2026-11-06 record: The then-current integrated internal TestFlight build was **1.2.6 (310)** on `test/watchos-126-310`, commit `d6ecea38`. It contains the full 1.2.6 watch integration and the live paired-playback fix in PR #1046. App Store Connect build `45f0ac2e-997e-4a98-9831-8ae65f1bd8f8` was **VALID**, uploaded, and **IN_BETA_TESTING** in the existing Internal Testing Group. English Chapter 115 notes were present; `autoNotifyEnabled` was true, although the CLI reported `notified: false` because the all-builds group was already assigned. The signed IPA's phone, independent watch and widget bundles all report 1.2.6 (310), and signatures and watch entitlements verify. Hardware behavior was not verified. See `docs/watchos-playback-sync-310.md` for the report, cause and fix, and `docs/watchos-device-testing.md` for the testing steps. Later build 311 was withdrawn from public beta after the watch-open phone crash; builds 312–314 and their remaining device checks are documented in [the distribution history](watchos-distribution.md) and [the 314 quality report](watchos-playback-quality-314.md).

Build 310 simulator verification: **20 watch unit tests and 4 watch UI tests passed** on watchOS 26.5 (`/tmp/EarshotWatchLiveFinalPass.xcresult`). The full iPhone run passed **2,742 unit tests with 34 existing skips**, and **40 UI tests with 7 device-specific skips**, with zero failures (`/tmp/EarshotPhoneLiveFull.xcresult`). A focused iPhone playback/connectivity suite passed 38 tests. Three targeted iPadOS 27.2 UI tests passed, including selected-sidebar VoiceOver state and largest-text Library navigation (`/tmp/Earshot310iPadUI.xcresult`). The signed Release archive and export succeeded. Simulator results do not establish physical Watch Connectivity, background audio, Bluetooth or VoiceOver behavior.

The following 309 record is retained as distribution history.

Integrated candidate version: **1.2.6 (309)** on `feature/watchos-126-integration`. Commit `5d9220ae` merges the complete watch implementation at `54675578` with the latest 1.2.6 Duo/iPad source at `f34d2897`, including the post-306 Library sidebar fix. Both parents are ancestors of the merge. App Store Connect reports 1.2.5 as the current App Store version; 1.2.6 (306) was the latest development build before this integration. Apple rejected uploads 307 and 308 during validation; build **309** is now processed and valid. Build 306 was uploaded at 09:48:44 Pacific on 2026-11-06, shortly after source commit `dff6cc09` at 09:48:29; App Store Connect does not expose a source commit for this build, so its exact SHA is unverified. The earlier unsigned 307 archive and signed 307 IPA showed the iPhone, independent watch and widget bundles, but Apple rejected their watch app location. The watch Info.plist declares independent installation, background audio and the Release CloudKit gate. The earlier unsigned 1.2.5 (299) archive is historical evidence, not the current candidate.

**Distribution status:** Michael accepted the updated Program License Agreement and signed into Xcode. Both watch App IDs have the approved App Group; the watch app also has the existing CloudKit container. The three App Store provisioning profiles are active. Build 307 was rejected with **90680** for embedding the watch app in `PlugIns`; XcodeGen now embeds it in `Watch`. Build 308 was rejected with **90626** for four App Intent descriptions containing “Apple”; those descriptions were corrected without changing intent identifiers or behavior. The signed **1.2.6 (309)** archive and App Store IPA contain the phone, independent watch and widget bundles under the correct paths. All signatures and watch entitlements were inspected. App Store Connect build ID `02931f5f-0fa3-462b-b152-4698f6d508b9` is **VALID**, upload state **COMPLETE**, and internal state **IN_BETA_TESTING**. The existing Internal Testing Group has access to all builds; the 309 English test notes are present and automatic notifications are enabled. This is an internal hardware evaluation build, not a public release.

## Implemented and compiled

| Approved phase | Implementation state | Remaining release proof |
| --- | --- | --- |
| 1. Foundation | Watch target, independent launch, generated project and tests | Signed watch provisioning |
| 2. Portable core and library | Shared identity/parser, local SwiftData, Library, Inbox and folders | Live CloudKit account/bootstrap |
| 3. Independent player | Direct stream/local AVPlayer, controls, chapters, sleep and remote commands | Background, route and interruption hardware pass |
| 4. Downloads and bookmarks | Direct validated downloads, restart/cancel/delete, local bookmarks | Offline and low-storage hardware pass |
| 5. Device coordination | Watch Connectivity control/handoff, private projection reconciliation, offline outbox | Two-device conflict and handoff hardware pass |
| 6. Widgets, intents, hardening | Accessory widget, watch shortcuts, code accessibility review and automated suites | Widget tap, VoiceOver, signed TestFlight processing |

- Independent watchOS 11 target `media.payown.earshot.watchkitapp`, watch unit/UI test targets, iPhone embedding in `Watch`, and watch background-audio Info.plist entry.
- Watch-local SwiftData models separate from all frozen phone schemas and the phone store. Shared phone RSS parser, chapter parser, product identifiers, logger, and sleep-timer rules are compiled into the watch target.
- Watch UI for Home, Library, podcast/episode details, Inbox, Queue, Downloads, Bookmarks, Settings, Now Playing, and optional iPhone control. The Library can fetch an HTTPS RSS feed directly, and episode playback and downloads use watch networking and storage.
- Watch AVPlayer with `.longFormAudio` session activation, skip/seek/speed, Podcasting 2.0 and show-note chapters, sleep timer, interruption and headphone-disconnect pause, Now Playing metadata, and remote commands.
- Optional Watch Connectivity phone-control messages with explicit accepted/failure responses and a bounded subscription-metadata import. The watch does not wait for the phone to launch or browse its local library.
- Watch-to-phone handoff checks that the phone has the episode, requests playback, then stops watch audio only when the reply identifies that episode as playing. Phone-to-watch handoff starts watch audio before requesting phone pause; a failed pause stops watch audio. These protocols still require device and failure-injection testing.
- Watch WidgetKit extension reads a compact app-group playback snapshot and deep-links to Now Playing. Watch App Intents open Now Playing and pause watch audio. The watch app has an icon asset.
- RSS retrieval stops at 20 MB even without a Content-Length header. Download validation rejects common HTML/XML error bodies and preserves supported media extensions. Explicit playback/download/phone-control outcomes are announced through the watch accessibility API. Episode row double tap now plays; Details is a separate control. Seeking uses an adjustable Slider with seconds in its spoken value.
- Exact existing Cloud projection model declarations were moved to a shared source file, with no field changes, so the watch can compile against the established record contract. Watch CloudKit coordination is not enabled yet.
- iPhone and watch simulator targets build. A direct `simctl install` and `simctl launch` of the watch app succeeded, and its Home was visually inspected. The RSS/parser watch unit test passed.

## Required before an integrated test build

- Validate the watch projection against a real two-device CloudKit account and extended offline conflicts. Current code handles the main state types, but schema deployment, account propagation timing, folder edits and tombstone retention still need physical integration proof. Current paired import remains an optional bootstrap path.
- Prove both handoff directions, timeout and crash recovery on physical devices. The sender waits for audio readiness and a matching acknowledgement, but a lost acknowledgement after the other device starts can leave an ambiguous state; the UI reports this and requests reconciliation.
- Test direct download cancellation, storage pressure and offline playback on hardware. Watch transfers use foreground `URLSession` and restart an interrupted transfer; watchOS does not guarantee unlimited background transfer execution. iPhone-to-watch selection sends a queued request and the watch downloads directly.
- Verify widget extension activation, deep links and App Intents on device. The `widgetURL` and matching `onOpenURL` handler are present as Apple documents. `simctl openurl` against the watchOS simulator returned `LSApplicationWorkspaceErrorDomain 115`, so a widget tap has not been proven by that command.
- Add more deterministic end-to-end sync tests where the system frameworks allow. After the 1.2.6 merge, the watch unit/UI suite passed **18 of 18** on Series 11/watchOS 26.5 and **18 of 18** on 42 mm watchOS 27.0 simulators (`/tmp/Earshot307Watch.xcresult` and `/tmp/Earshot307Watch27.xcresult`). The iPhone unit suite passed **2,705, with 34 skipped and zero failed** on iPhone 17 Pro/iOS 26.0 simulator (`/tmp/Earshot307PhoneUnits.xcresult`). The iPhone UI suite passed **33, with 7 device-specific skips and zero failed** (`/tmp/Earshot307PhoneUI.xcresult`). Dedicated iPad UI checks on iPadOS 27.2 passed **3, with 1 expected compact-iPhone skip and zero failed** (`/tmp/Earshot307iPadUI.xcresult`), including selected-sidebar VoiceOver state. An iPad mini large-text UI case passed **1 of 1** on iPadOS 27.2 (`/tmp/Earshot307iPadMiniUI.xcresult`). The two known StoreKit simulator suites were excluded by repository policy. The structured accessibility code review is in `docs/watchos-accessibility-review.md`; physical VoiceOver/device checks remain.
- Validate universal purchase on watch hardware without changing purchase UI. Signed 309 archive, IPA packaging and internal TestFlight processing passed.

## Current testing limits

The physical Apple Watch is listed by `devicectl` as unavailable. A simulator can verify compilation, installation, navigation and pure logic, but cannot prove Bluetooth routing, cellular streaming, background audio, Watch Connectivity delivery or handoff. The watch unit/UI and iPhone unit suites passed after the 1.2.6 merge; build 309 reran all **18 watch tests** and **16 iPhone shortcut tests** with zero failures; independent launch UI tests also passed earlier on a 40 mm watchOS 26.5 simulator and a 42 mm watchOS 27.0 simulator. The 307 Release **watchOS Simulator** app installed and launched successfully (PID 2704). Installing the device-archive watch binary in the simulator was denied, as expected: its Mach-O platform is WATCHOS rather than WATCHOSSIMULATOR. A watch UI test earlier exposed a Swift 6 executor violation in a Watch Connectivity callback; direct Release launch exposed the unsigned CloudKit entitlement trap. Both were corrected and their affected paths reran successfully. The watch App Group and existing CloudKit container are assigned in the Developer portal, and valid App Store profiles are installed. Signed 309 packaging and TestFlight validation passed. Physical Watch Connectivity, CloudKit, Bluetooth, cellular, offline, background audio and VoiceOver behavior remain to be verified by Michael.

The build 310 candidate is kept in the linked worktree `/Users/michaelbabcock/code/earshot-watch-310-testing` on `test/watchos-126-310`; the reviewable fix is in PR #1046. Do not merge to `main` or release publicly before Michael's physical-device approval.

The foundation slice is in [draft PR #1045](https://github.com/payown/earshot/pull/1045), targeted to `main` and assigned to `@payown`; its `Build and test (EarshotTests)` CI check passed. It stays unmerged. The integrated branch contains later dependent commits; follow-up PRs will be opened in slices that meet the repository's 1,500-line non-generated limit after the foundation is approved, rather than posting one oversized integration PR.

The current iOS target now includes iPhone and iPad (`TARGETED_DEVICE_FAMILY = 1,2`) from the 1.2.6 development branch. The integrated watch branch preserves its scene-based native iPad support; iPad simulator and device checks are required alongside phone regression testing.
