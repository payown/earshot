# Siri and Search: content foundation

## User behavior

Settings → Siri and Search is off by default. Enabling it permits donation of
podcast/episode titles and cleaned descriptions from the local library, including
private subscriptions. It does not donate audio, transcripts, bookmark notes,
feed addresses, or audio URLs. Identifiers are opaque hashes of canonical feed
identity plus the episode GUID; identical titles do not collide.

Spotlight results open the podcast or the existing episode show-notes view.
Opening never starts playback. This stage does not implement iOS 27 audio
schemas, natural-language media playback, transcript question answering, or
onscreen awareness. Existing skip-forward/back shortcuts continue unchanged.

## Selection and performance

The snapshot includes at most 1,000 followed shows, 500 recent followed episodes,
100 unfinished episodes, the first 200 queue entries, 100 recent bookmarks, and
100 downloaded-episode records. Episodes are deduplicated by identity. Explicitly
retained catalog episodes can participate without following their show. These
are selection caps, not a promise that every retained episode is indexed.

All store selection and text cleanup run in a dedicated background model actor.
No SwiftData model crosses the actor boundary. Spotlight submissions use batches
of 50. Saves and foreground transitions request reconciliation; ordinary updates
are coalesced and throttled to at most once a minute after the first snapshot.
Indexing begins after a three-second grace. There is no idle polling loop.

The index is device-local, named, and derived from the current database. Each
process start rebuilds it to reconcile interrupted writes, restore, and library
replacement. During the process, only changed records are submitted and removed
records are deleted. Unchanged entries are renewed on reconciliation at least a day after their last
full donation. Entries expire after seven days without a fresh donation.
Core Spotlight delegate requests trigger a full rebuild. No new entitlement,
signing change, SwiftData migration, or third-party dependency is required.

## Opt-out and reset

Opt-out requests removal of the entire named index. Failures are shown in the
settings screen and retried while the app is running, and on the next launch.
Queries and navigation reject search content immediately when disabled.

After the existing sync-deletion preparation succeeds, reset disables indexing,
cancels and joins the current writer, and waits for
Spotlight deletion before the existing reset transaction begins. A failed
Spotlight deletion blocks reset success and resumes maintenance so removal can
retry and the user can enable indexing again. This is the only reset integration;
the protected legacy Flutter database cleanup remains untouched.

## Validation before release

Automated coverage exercises stable identity, duplicate titles, metadata cleanup,
selection limits, retained catalog episodes, canonical download identity, custom
show names, deletion reconciliation, renewal, and recovery after failed removal.

Validation on 2026-09-15: the Debug simulator app built with the required Xcode
26.6 / Swift 6.3.3 toolchain. All 48 tests in `LibrarySearchTests`,
`PlaybackSkipIntentTests`, and `AppRuntimeTests` passed on iOS 26.5. This includes
cold intent startup without playback and reset joining an in-flight donation.
An independent review found reset-retry, modal routing, renewal, canonical feed,
and custom-name issues; those were corrected and re-reviewed with no remaining
blocking findings.

Physical-device acceptance is still required:

1. Opt in, search for an indexed title and description phrase, and open a result
   with Earshot cold and warm. Confirm the correct notes and unchanged playback.
2. Repeat while a modal is open, during onboarding, and with duplicate titles.
3. Rename, delete, unfollow, and sync content; confirm stale results disappear.
4. Disable indexing and reset the library; confirm results disappear and remain
   absent after relaunch. Check retry behavior when Spotlight fails.
5. Test a large real library while listening with VoiceOver. Measure launch,
   focus, speech responsiveness, audio continuity, and incremental update cost.
6. Test the iOS 18 baseline as well as the current supported OS. Search ranking
   and richer Siri behavior remain controlled by the system.

## Next stage

After an approved toolchain upgrade, add availability-gated iOS 27 podcast/audio
schemas and Media Intents queries. Add explicit play/resume intents through the
existing playback service and donate successful user-initiated actions without
duplicating Siri/Shortcuts donations. Keep transcript indexing separate.

## Apple references

- [Indexing entities](https://developer.apple.com/documentation/appintents/making-app-entities-available-in-spotlight)
- [Opening entities](https://developer.apple.com/documentation/appintents/openintent)
- [Audio schemas](https://developer.apple.com/documentation/appintents/app-schema-domain-audio)
