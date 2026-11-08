# Watch and iPhone live playback, build 310

## Listener report and cause

On 1.2.6 (309), Michael played an episode on iPhone but did not see it as currently playing when he opened Earshot on Apple Watch. He reported that the watch buttons appeared to be labeled correctly with VoiceOver. This is a physical-device observation; the exact episode and OS versions were not supplied. StartTesting item `14bac988-5bcb-4f98-b12b-578ecf7df77e` tracks acceptance.

Code review found that Watch Home displayed only `WatchPlayer.episode`. The watch requested iPhone state on WCSession activation/reachability and when the separate iPhone Control screen opened; an already active session did not guarantee another activation callback on app foreground. The phone answered explicit commands but did not proactively publish player changes. CloudKit projection stores durable progress, not current transport state, so it cannot fill this live UI gap.

## Transport and ownership

`PairedPlaybackState` is a versioned, small transport value containing source device, feed and episode identity, title, podcast, media URL, position, rate, play/pause state and observation time. Each device remains the sole writer of its own playback snapshot. Watch Connectivity application context carries the latest state across suspension and reconnection; an immediate message carries the same snapshot when the peer is reachable. Newer observations win when a delayed context arrives after an immediate message. A state older than 45 seconds is labeled last reported and cannot authorize a transfer. No periodic network or CloudKit poll was added; observation of player state publishes changes immediately for episode, transport, rate and seek changes, and at most once per 20 seconds during ordinary progress. App activation/background and WCSession changes force a latest-state publication. The watch requests an explicit fresh state when opened or reconnected, without waiting indefinitely if iPhone is unavailable.

Watch Home keeps a stable iPhone playback row at the top with podcast, episode, position and source status. Now Playing shows the live iPhone session when the watch itself is not playing. Each device's control screen identifies its source and offers direct pause, play, skip, refresh and explicit transfer. Background or offline state is marked last known rather than claiming current playback. Passive position updates do not trigger VoiceOver announcements.

Transfers request fresh source state, start the matching episode on the receiving device at the reported position and rate, and require an identity-matched pause acknowledgement from the source. A failed start or missing pause acknowledgement stops the newly started audio and reports the uncertainty. Handoff speed is session-only; it does not overwrite the receiving device's saved speed preference. Existing CloudKit queue/progress reconciliation remains responsible for durable offline edits; a transport snapshot does not rewrite queue or listening history.

## Verification and limits

The deterministic tests cover snapshot encoding, immediate publication decisions, stale and out-of-order updates, ownership, source pause acknowledgements and session-only speed. Simulator UI tests cover the stable Home row, iPhone Control access without a phone, and existing watch navigation. The repository earshot-accessibility review found and corrected a missing spoken position, an unstable Home section, and premature handoff announcements. Actual Watch Connectivity delivery, background execution timing, two-device transfer, Bluetooth and VoiceOver focus/announcement timing still require Michael's physical-device pass. There is no claim of hardware confirmation in this document.

The watch can stream and play downloads independently. A disconnected iPhone neither disables those paths nor causes an endless spinner. App Store/TestFlight status for the actual uploaded build is recorded in `docs/watchos-progress.md` after processing.
