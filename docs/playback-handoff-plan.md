# Direct playback handoff plan

Status: implementation in progress on `codex/direct-playback-handoff`.

## Outcome

When a listener deliberately starts or resumes an episode, Earshot performs one
explicit lookup in the user's private CloudKit database before starting audio.
It uses the returned position and effective playback rate when the lookup
finishes within 1.5 seconds. Offline, unavailable, and slow requests fall back to
the device's local state without blocking playback indefinitely.

Automatic SwiftData/CloudKit projection remains the eventual-sync and migration
fallback for subscriptions, queue, folders, history, played state, and playback
state. The direct record is a latency-sensitive handoff channel, not a second
copy of the library.

## Record contract

- Private database record type: `EarshotPlaybackHandoff`
- One record per canonical feed URL + episode GUID
- Deterministic record ID: `handoff-v1-` plus a SHA-256 identity digest
- Default private zone; the app fetches by record ID, so no query index is needed
- Fields:
  - `schemaVersion` — Int64, initially 1
  - `feedURL` — String
  - `episodeGUID` — String
  - `positionSeconds` — Int64
  - `playbackRate` — Double
  - `eventID` — String UUID for idempotence
  - `eventDate` — Date for rejecting delayed older writes
  - `sourceDeviceID` — String diagnostic identity

The record contains private playback state already covered by Earshot's iCloud
privacy description. It contains no title, description, audio, download path,
purchase state, advertising identifier, analytics identifier, or relationship.

## Write policy and energy budget

Direct writes occur only at durable playback boundaries:

- pause;
- explicit seek/skip;
- current-episode switch;
- app background;
- explicit playback-rate change;
- played/completed transition; and
- stop/unload while the episode still exists.

There is no direct write on the one-second playback observer and no periodic
direct write. The existing compact projection retains its one-minute progress
fallback. This keeps direct CloudKit traffic proportional to user actions and
avoids recreating the large-library heat/main-thread regression fixed in #736.

The newest unsent boundary for each episode is written to a bounded local outbox
before network I/O. The outbox keeps at most 32 episodes. A fetch retries that
episode's pending boundary first; if it remains offline, local state wins and
Earshot does not apply an older server position.

## Read and conflict policy

User-initiated episode start and resume perform one user-initiated record fetch.
Automatic queue advance and bookmark jumps do not wait: queue continuity must
remain gapless, and an explicit bookmark position must win.

The server record is last-intent-wins, not greatest-position-wins. This is
required for rewinds. CloudKit change tags serialize concurrent updates; a
server-record-changed response is refetched and retried. `eventDate` rejects an
older delayed operation, while `eventID` makes retries idempotent.

A fetched rate is a session-only override for the loaded episode. It does not
silently rewrite global or per-podcast preferences. A deliberate local speed
change supersedes it immediately. The automatic settings projection continues
to synchronize persistent speed preferences eventually.

## Responsiveness and accessibility

- CloudKit work runs asynchronously; the main actor performs no network I/O.
- Playback falls back to local state after 1.5 seconds.
- A generation token discards a late fetch after pause, deletion, episode switch,
  reset, or another playback request.
- Existing labels, values, traits, rotor actions, focus, and announcements remain
  unchanged in the first implementation.
- Device testing must confirm whether silence during a slow preflight fetch needs
  a concise VoiceOver-only status announcement. Do not add one without testing;
  unnecessary announcements would make ordinary fast resumes noisier.

## Compatibility and rollout

1. Land the client, player integration, unit tests, and this contract.
2. Run regression suites for player, persistence, projection, reset, queue, and
   large-library performance.
3. Use a CloudKit Development build to create and inspect
   `EarshotPlaybackHandoff` and its eight fields.
4. Verify that no indexes or public/shared security grants were created.
5. Run physical iPhone-to-Mac and Mac-to-iPhone tests, including rewind, offline,
   timeout, background, concurrent playback, and rate changes.
6. Deploy the new record type to Production only after its schema diff matches
   this document.
7. Upload a new TestFlight build to both tester groups and explicitly request
   handoff, energy, and crash feedback.

Older builds ignore the new record. New builds seeing no record immediately use
their existing local/projection state, so rollout does not require a bulk data
migration. The first durable playback boundary creates the record lazily.

## Later cleanup decision

Direct records are small but currently retained. Before declaring the design
permanent, choose and test one cleanup rule:

- retain records while the episode exists on any device; or
- delete records after a conservative age once played-state convergence is
  confirmed.

Do not add short-lived cleanup: a device can remain offline for months, and an
early deletion would discard the exact state this mechanism exists to preserve.

## Apple references

- [Fetching a specific CloudKit record](https://developer.apple.com/documentation/cloudkit/ckdatabase/record(for:))
- [CloudKit record save policies and change tags](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/savepolicy)
- [CloudKit private databases](https://developer.apple.com/documentation/cloudkit/ckdatabase)
- [Core Data/CloudKit scheduling limitations](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)
