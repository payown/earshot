# Earshot Watch implementation progress

Updated 2026-11-06. The integrated device build is **not ready**. This file records implementation state so work can continue without treating an intermediate simulator build as the release candidate.

## Implemented and compiled

- Independent watchOS 11 target `media.payown.earshot.watchkitapp`, watch unit/UI test targets, iPhone embedding in `PlugIns`, and watch background-audio Info.plist entry.
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

- Complete durable CloudKit/watch state reconciliation, including subscription, queue, played state, progress, bookmarks and preference conflicts. Current paired import is a bootstrap action, not full sync.
- Harden both handoff directions with durable transaction IDs, playback readiness, timeout and crash recovery, and physical-device tests. The current request/reply flow is an early implementation, not yet a proven transactional guarantee.
- Improve direct download progress, validation, cancellation recovery and watch background-transfer behavior; test offline playback and storage failure.
- Expand the WidgetKit content and App Intents; verify extension activation and deep links in simulator and on device.
- Add deterministic connectivity, download, playback and sync tests; broaden watch UI tests and iPhone regression tests. Run the required `earshot-accessibility` review and physical VoiceOver/device checks.
- Validate universal purchase on watch hardware without changing purchase UI. Verify signed archive packaging and TestFlight distribution.

## Current testing limits

The physical Apple Watch is listed by `devicectl` as unavailable. A simulator can verify compilation, installation, navigation and pure logic, but cannot prove Bluetooth routing, cellular streaming, background audio, Watch Connectivity delivery or handoff. The watch UI test now passes with the visible Now Playing link. The independent watch unit tests and both generic simulator builds have passed; broader regression testing remains.

The source work is kept in the linked worktree on `feature/watchos-architecture`. Do not upload this intermediate build or merge it to `main`.
