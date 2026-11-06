# Earshot Watch implementation progress

Updated 2026-11-06. The integrated device build is **not ready**. This file records implementation state so work can continue without treating an intermediate simulator build as the release candidate.

## Implemented and compiled

- Independent watchOS 11 target `media.payown.earshot.watchkitapp`, watch unit/UI test targets, iPhone embedding in `PlugIns`, and watch background-audio Info.plist entry.
- Watch-local SwiftData models separate from all frozen phone schemas and the phone store. Shared phone RSS parser, chapter parser, product identifiers, logger, and sleep-timer rules are compiled into the watch target.
- Watch UI for Home, Library, podcast/episode details, Inbox, Queue, Downloads, Bookmarks, Settings, Now Playing, and optional iPhone control. The Library can fetch an HTTPS RSS feed directly, and episode playback and downloads use watch networking and storage.
- Watch AVPlayer with `.longFormAudio` session activation, skip/seek/speed, Podcasting 2.0 and show-note chapters, sleep timer, interruption and headphone-disconnect pause, Now Playing metadata, and remote commands.
- Optional Watch Connectivity phone-control messages with explicit accepted/failure responses and a bounded subscription-metadata import. The watch does not wait for the phone to launch or browse its local library.
- iPhone and watch simulator targets build. A direct `simctl install` and `simctl launch` of the watch app succeeded, and its Home was visually inspected. The RSS/parser watch unit test passed.

## Required before an integrated test build

- Complete durable CloudKit/watch state reconciliation, including subscription, queue, played state, progress, bookmarks and preference conflicts. Current paired import is a bootstrap action, not full sync.
- Complete transactional handoff in both directions. The control screen deliberately has no transfer button until the receiving device can confirm readiness before the source stops.
- Improve direct download progress, validation, cancellation recovery and watch background-transfer behavior; test offline playback and storage failure.
- Add a WidgetKit extension, complications/Smart Stack content, watch App Intents and deep links.
- Add deterministic connectivity, download, playback and sync tests; broaden watch UI tests and iPhone regression tests. Run the required `earshot-accessibility` review and physical VoiceOver/device checks.
- Validate universal purchase on watch hardware without changing purchase UI. Verify signed archive packaging and TestFlight distribution.

## Current testing limits

The physical Apple Watch is listed by `devicectl` as unavailable. A simulator can verify compilation, installation, navigation and pure logic, but cannot prove Bluetooth routing, cellular streaming, background audio, Watch Connectivity delivery or handoff. The initial UI test located Home but failed when looking for an offscreen Library link; the test now checks the visible Now Playing link and needs rerun.

The source work is kept in the linked worktree on `feature/watchos-architecture`. Do not upload this intermediate build or merge it to `main`.
