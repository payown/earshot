# Earshot Watch implementation progress

Updated 2026-11-06. The integrated device build is **not ready**. This file records implementation state so work can continue without treating an intermediate simulator build as the release candidate.

Integrated candidate version: **1.2.5 (299)**. The unsigned Release archive embeds `media.payown.earshot`, `media.payown.earshot.watchkitapp`, and `media.payown.earshot.watchkitapp.widgets` with matching versions. The watch Info.plist includes independent installation, background audio, and the Release CloudKit gate. Signing, export and TestFlight processing remain to be verified.

## Implemented and compiled

- Independent watchOS 11 target `media.payown.earshot.watchkitapp`, watch unit/UI test targets, iPhone embedding in `PlugIns`, and watch background-audio Info.plist entry.
- Watch-local SwiftData models separate from all frozen phone schemas and the phone store. Shared phone RSS parser, chapter parser, product identifiers, logger, and sleep-timer rules are compiled into the watch target.
- Watch UI for Home, Library, podcast/episode details, Inbox, Queue, Downloads, Bookmarks, Settings, Now Playing, and optional iPhone control. The Library can fetch an HTTPS RSS feed directly, and episode playback and downloads use watch networking and storage.
- Watch AVPlayer with `.longFormAudio` session activation, skip/seek/speed, Podcasting 2.0 and show-note chapters, sleep timer, interruption and headphone-disconnect pause, Now Playing metadata, and remote commands.
- Optional Watch Connectivity phone-control messages with explicit accepted/failure responses and a bounded subscription-metadata import. The watch does not wait for the phone to launch or browse its local library.
- Watch-to-phone handoff checks that the phone has the episode, requests playback, then stops watch audio only when the reply identifies that episode as playing. Phone-to-watch handoff starts watch audio before requesting phone pause; a failed pause stops watch audio. These protocols still require device and failure-injection testing.
- Watch WidgetKit extension reads a compact app-group playback snapshot and deep-links to Now Playing. Watch App Intents open Now Playing and pause watch audio. The watch app has an icon asset.
- RSS retrieval stops at 20 MB even without a Content-Length header. Download validation rejects common HTML/XML error bodies and preserves supported media extensions. Explicit playback/download/phone-control outcomes are announced through the watch accessibility API. Episode row double tap now plays; Details is a separate control. Seeking uses an adjustable Slider with seconds in its spoken value.
- Exact existing Cloud projection model declarations were moved to a shared source file, with no field changes, so the watch compiles against the established record contract.
- The existing feed URL identity rules are shared with watchOS, preserving path and query case when matching subscriptions and episodes.
- A separate watch Cloud projection store now uses those exact seven model types. Release/CloudKitDevelopment enable the approved existing private container; Debug remains local-only. A compact watch SwiftData outbox retains offline follow/unfollow, progress, played, inbox, queue, bookmark and skip-setting edits. Reconciliation applies the phone projection's explicit progress-reset and queue-membership clocks. Folder membership is read from the existing projection for watch Library browsing.
- Watch Connectivity now carries acknowledged two-way playback commands, a cached Quick Actions order, and queued iPhone-to-watch download requests. The iPhone Settings screen can select an episode for direct watch download; the watch can process a request after reconnecting.
- The watch exposes a separate App Intents implementation for Open Now Playing, Resume, Pause and Skip, and the iPhone has a Send Episode to Watch shortcut. The watch widget supports circular, rectangular and inline accessory families with bounded snapshot freshness.
- The watch Now Playing screen identifies the audio route and offers Restart. At episode end, it marks played and advances to Up Next. Missing download files are detected on launch; completed downloads are checked with AVFoundation before they become playable. Show notes use the existing shared paragraph parser.
- iPhone and watch simulator targets build. A direct `simctl install` and `simctl launch` of the watch app succeeded, and its Home was visually inspected. The RSS/parser watch unit test passed.

## Required before an integrated test build

- Validate the watch projection against a real two-device CloudKit account and extended offline conflicts. Current code handles the main state types, but schema deployment, account propagation timing, folder edits and tombstone retention still need physical integration proof. Current paired import remains an optional bootstrap path.
- Prove both handoff directions, timeout and crash recovery on physical devices. The sender waits for audio readiness and a matching acknowledgement, but a lost acknowledgement after the other device starts can leave an ambiguous state; the UI reports this and requests reconciliation.
- Test direct download cancellation, storage pressure and offline playback on hardware. Watch transfers use foreground `URLSession` and restart an interrupted transfer; watchOS does not guarantee unlimited background transfer execution. iPhone-to-watch selection sends a queued request and the watch downloads directly.
- Verify widget extension activation, deep links and App Intents in simulator and on device.
- Add more deterministic end-to-end sync tests where the system frameworks allow. The watch unit/UI suite passed with **14 passed, zero failed** on Series 11/watchOS 26.5 simulator. The iPhone unit suite passed with **2,702 passed, 34 skipped, zero failed** on iPhone 17 Pro/iOS 26.0 simulator on 2026-11-06. The two known StoreKit simulator suites were excluded by repository policy. The structured accessibility code review is in `docs/watchos-accessibility-review.md`; physical VoiceOver/device checks remain.
- Validate universal purchase on watch hardware without changing purchase UI. Verify signed archive packaging and TestFlight distribution.

## Current testing limits

The physical Apple Watch is listed by `devicectl` as unavailable. A simulator can verify compilation, installation, navigation and pure logic, but cannot prove Bluetooth routing, cellular streaming, background audio, Watch Connectivity delivery or handoff. The watch unit/UI and iPhone unit suites passed; a signed archive remains. A watch UI test initially exposed a Swift 6 executor violation in a Watch Connectivity callback. The callback was corrected and the complete watch suite reran successfully.

The source work is kept in the linked worktree on `feature/watchos-architecture`. Do not upload this intermediate build or merge it to `main`.
