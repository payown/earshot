# Listening Places: Earshot 1.2.0 implementation plan

**Status:** implemented on a feature branch based on Earshot 1.1.1 build 211
**Source:** `sync.html`, “Listening Places: cross-app resume sync over a folder you already have,” 2026-08-20
**Target:** Earshot 1.2.0

## Physical-device validation

- Confirmed write and folder creation in iCloud Drive on an iPhone 17 Pro Max.
- Confirmed write and nested folder creation at the Dropbox root.
- Confirmed write inside the shared `Jeff and Michael` Dropbox folder after
  clearing Dropbox's stale iOS File Provider cache. Before the cache reset,
  Apple's Files app could not materialize the folder and Earshot correctly
  surfaced the provider's Cocoa error without affecting local listening state.
- Folder selection now proves the destination is writable before replacing the
  last working bookmark.

## Recommendation

Ship a deliberately write-only first release. Earshot should maintain one
`listening-places/1` device file in a user-selected Files folder, but it should
not read or apply another app's state in 1.2.0. This proves persistent folder
access and interoperability without allowing folder contents to change the
local library or the active player.

The proposal was written against the retired Flutter/Drift implementation.
Earshot 1.1.1 is a native SwiftUI and SwiftData app and already has compact,
per-device playback projections. The native implementation therefore needs no
Flutter platform channel, Drift migration, or new third-party dependency.

## Findings from the 1.1.1 code

- `EpisodeUserStateSnapshot` and `.earshotEpisodeUserStateDidChange` already
  provide the bounded, activity-driven save boundary the writer needs.
- `CloudEpisodeStateProjection` already records `positionUpdatedAt`,
  `playedUpdatedAt`, resets, and a source device ID. Adding another timestamp
  to every `Episode` would duplicate this work and trigger a migration over
  libraries known to exceed 242,000 episodes.
- Player persistence is already throttled and publishes snapshots after durable
  saves. Listening Places must subscribe to that event; it must never add file
  I/O to `PlayerService` or a playback callback.
- SwiftUI's system file importer can select `UTType.folder`. Native bookmark and
  coordinated-file APIs can persist access directly; no platform bridge is
  required.
- Folder bookmark data, the Listening Places device ID, and write status are
  device-local settings. They must not enter Earshot's mirrored settings store.
- The current iCloud sync format keys episode state by canonical feed URL plus
  GUID. The public format intentionally uses a hash of the trimmed GUID alone.
  The adapter must preserve that distinction rather than changing Earshot's
  internal identity rules.

## 1.2.0 scope

### Included

1. Publish and test the `listening-places/1` episode record format.
2. Select a folder using the accessible system Files picker.
3. Persist a security-scoped bookmark locally and detect stale bookmarks.
4. Create `Listening Places/README.txt` and
   `Listening Places/devices/<device-id>.json`.
5. Seed the file from meaningful local episode state when the feature is
   enabled.
6. Update Earshot's device file after durable episode-state changes, debounced
   until activity has been quiet for one minute.
7. Flush best-effort when the app backgrounds.
8. Skip byte-identical writes and cap output at the 1,000 most recently updated
   records.
9. Explicitly report “Earshot 1.2.0 writes outward only. It does not import
   another device's changes yet.”
10. Stop syncing by removing only this device's file and local bookmark/config.

### Excluded

- Reading or merging another device's file.
- Moving a loaded player's position.
- Subscriptions, folders, queue, bookmarks, or listening-history exchange.
- Local-file content hashing; Earshot does not yet expose the proposal's
  universal local-audio import surface.
- Encryption and recovery phrases.
- File watching, timers, foreground-triggered reads, or background execution.
- Changes to Earshot's existing iCloud entitlements, CloudKit transport, or
  signing configuration.

## Native architecture

### Interchange domain

`Features/ListeningPlaces/Domain/ListeningPlacesFormat.swift`

- Codable, Sendable device-file and record values.
- `episode:` identity from the first 16 lowercase hexadecimal SHA-256
  characters of the trimmed RSS GUID, falling back to the trimmed enclosure URL
  only when the GUID is absent. This matches QUILL's shipped implementation;
  its normalization is more specific than the proposal prose.
- Millisecond conversion, RFC 3339 UTC dates, optional labels, deterministic
  ordering, a 1,000-record cap, and stable JSON bytes.
- QUILL's normative desktop and phone device fixtures are checked into both
  repositories and decoded directly. The expected-merge fixture remains in
  QUILL until Earshot adds bidirectional merging after 1.2.0.

### Device-local configuration

`Features/ListeningPlaces/Data/ListeningPlacesService.swift`

- Store bookmark data, random device ID, optional device label, include-labels
  preference, last successful write, and last error.
- Keep these values device-local. Prefer the existing `LocalAppSetting` path so
  factory-reset behavior stays centralized; do not add them to
  `AppSettingScope.mirroredKeys`.
- Bookmark data should be base64 encoded if stored through the string-valued
  settings API.

### Folder transport

`Features/ListeningPlaces/Data/ListeningPlacesFileTransport.swift`

- Resolve the security-scoped bookmark for each operation and balance every
  successful `startAccessingSecurityScopedResource()` call with
  `stopAccessingSecurityScopedResource()`.
- Coordinate reads and writes with `NSFileCoordinator`.
- Use coordinated atomic replacement for the device file.
- Treat provider placeholders and unavailable folders as asynchronous failures.
  A failure never blocks playback and never clears local progress.
- Perform file work away from the main actor. Return small Sendable results for
  presentation.

### Writer coordinator

`Features/ListeningPlaces/Data/ListeningPlacesService.swift`

- Observe `.earshotEpisodeUserStateDidChange` after the existing durable save.
- Keep pending records in an actor and debounce the transport flush for 60
  seconds. Pause, stop, completion, explicit played/unplayed, and backgrounding
  remain durability anchors.
- On enable, seed only meaningful state (`positionSeconds > 0` or played), using
  scalar fetches and never faulting `Podcast.episodes`.
- Merge new snapshots into this device's existing file so timestamps survive
  relaunch. Never read or interpret other device files in 1.2.0.
- Do not rewrite when the encoded bytes match the last successful bytes.

### SwiftUI setup and status

Add a separate “Listening Places” destination beside “iCloud Sync,” not inside
it. The two transports solve different problems and combining their status
would be misleading.

Use native `Form`, `Toggle`, `Button`, `LabeledContent`, and the system folder
picker. Keep the setting off by default. Required spoken behavior:

- “Choose sync folder” clearly identifies the system picker action.
- Status says that 1.2.0 writes outward only.
- Success and failure are announced only for user-requested operations; routine
  background writes remain silent.
- Failure copy is actionable and preserves confidence: “The sync folder could
  not be reached. Your place is still saved on this device.”
- Removing the device file requires a destructive confirmation and restores
  focus to a stable element.

Michael approved the proposed 1.2.0 behavior before the UI implementation.

## Delivery sequence

1. **Format spike:** land the pure Swift format/identity encoder and tests.
2. **QUILL conformance gate:** obtain QUILL's actual encoder fixtures and prove
   byte-independent decode/semantic compatibility in both repositories.
3. **Transport spike:** prove bookmark persistence and coordinated atomic writes
   on iCloud Drive, Dropbox, OneDrive, and Google Drive using a diagnostic-only
   screen or test harness.
4. **Writer integration:** seed, observe snapshots, debounce, cap, deduplicate,
   background flush, and remove-this-device behavior.
5. **VoiceOver-approved UI:** add the settings destination only after the spoken
   contract is approved.
6. **Release gates:** upgrade from build 211 with a large store; verify zero
   playback-path I/O; force quit during writes; revoke folder access; move or
   delete the folder; test offline provider placeholders; validate physical-
   device VoiceOver behavior.

## Required tests

- GUID and enclosure fallback identity vectors, including Unicode and whitespace.
- Exact millisecond conversion and unknown-duration behavior.
- RFC 3339 UTC encoding and decode compatibility.
- Stable ordering, 1,000-record cap, and deterministic tie breaking.
- Optional-label privacy behavior.
- Bookmark create/resolve/stale/reselect/revoked-access paths.
- Balanced security-scope access and coordinated atomic replacement.
- Debounce coalescing, unchanged-byte suppression, retry after failure, and
  best-effort background flush.
- No folder I/O from player methods or on the main actor.
- VoiceOver linear navigation, switch value, picker return focus, operation
  announcements, failure announcement, and destructive-confirmation focus.

Run the complete ordinary test suite without excluding the StoreKit suites.
Those suites pass on Xcode 26.6, so their stale environment quarantine was
removed from both the tests and CI. Opt-in device-copy and scale diagnostics
remain separate diagnostic jobs because their external fixtures are not unit
test inputs. Verify the folder transport on physical devices because Simulator
Files providers do not represent real third-party File Provider behavior.

## Approved decisions for 1.2.0

1. Write-only scope for 1.2.0; bidirectional read/merge is deferred.
2. Public identity follows QUILL's shipped code: trim GUID/enclosure input,
   prefer GUID, and hash to the first 16 lowercase SHA-256 characters.
3. Human-readable labels default off; raw feed URLs are always omitted.
4. Plain JSON in the user-selected folder is acceptable with the privacy copy.
5. The new VoiceOver labels, values, hints, and destructive confirmation are
   approved for implementation.
6. QUILL's normative device fixtures are mirrored under
   `EarshotTests/Fixtures/ListeningPlaces` and decoded by Earshot tests.

## QUILL reference

The separate checkout at `/Users/michaelbabcock/code/quill` is current through
commit `def32259`. The implementation references are
`quill/core/sync/listening_places.py`,
`quill/core/podcasts/position_sync.py`, and
`docs/engineering/listening-places-spec.md`.
