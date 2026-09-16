# Siri media search and listening suggestions

This stage builds with public Xcode 27.0 (27A266a), Swift 6.4, and XcodeGen
2.46.0. The deployment minimum remains iOS 18. The new schemas and MediaIntents
query are available only on iOS 27; existing Spotlight entities and Resume
shortcuts remain available on earlier supported systems.

## Playback

Siri can query Earshot's opted-in searchable selection through AudioSearch and
receive podcast episode entities conforming to Apple's podcastEpisode schema.
The media query and playAudio action both accept podcast episodes and shows.
A show selection starts its newest locally stored episode, even when that episode
is outside the global Spotlight episode selection. Explicit latest-episode
requests resolve the show first. A separate Play Latest Episode shortcut provides
the same operation in Shortcuts and a registered phrase for Siri. All
starts use the existing playback bridge, readiness checks, saved progress, and
handoff. They do not change the queue. Shuffle, repeat, queue insertion, and
warmup results return an explicit unsupported-options error.

Matching checks title and show words without case or accent sensitivity, tolerates
punctuation, and returns at most 20 results ordered by publication date. Unknown
or unmatched requests return no results. URL requests return no results: private
feed/audio URLs are not exposed as public entity links. This does not implement
semantic recommendations, transcripts, or an unrestricted search of all history.

## Listening donations

A separate setting, “Suggest episodes I choose to play”, is off by default and
requires the content-search opt-in. Selecting Play from an episode row marks a
single pending action; only actual AVPlayer playback of that episode submits the
action. Automatic advancement and Siri/Shortcuts playback do not create duplicate
manual donations. Other playback entry points currently do not donate actions.

The donation service serializes submission and removal, checks current consent,
and restricts donations to the current searchable selection. It replaces previous
manual donations for the same episode. Removing content reconciles its donation;
opt-out and reset wait for pending writes before deleting all donations of the
new playback intent type. Opaque donated identifiers are persisted before submission so startup can
remove stale donations while retaining allowed listening history. Spotlight
rebuilds do not clear that history. Consent removal runs before the content
refresh throttle. Cleanup failures use the index's existing retry path.

Existing VoiceOver labels and focus behavior are unchanged. The new setting uses
a native toggle and its own explanatory footer.

## Device findings and acceptance

Build 265.971: Michael verified podcast and episode Spotlight results, including
“The dangers of AI”, and opening show notes. A full-title query initially missed
and later worked, consistent with an indexing delay. Submission count alone is
not proof of search visibility.

Build 265.972: “Resume listening in Earshot” worked from paused playback and
while already playing (Siri briefly interrupted, then playback continued).
“Play an episode in Earshot” was rejected by Siri before Earshot opened. The
new media integration needs physical-device validation; compilation and unit
tests cannot verify Siri's routing or server-side availability.

Test named-episode playback, the generic episode request, duplicate titles,
show selection, cold launch, saved position, queue preservation, consent off,
removed content, and VoiceOver/audio continuity. Enable listening suggestions
separately to test user-selected playback and subsequent opt-out. Do not reset
a real library merely to test cleanup.

## References

- [Apple audio schemas](https://developer.apple.com/documentation/appintents/app-schema-domain-audio)
- [Responding to audio search and playback requests](https://developer.apple.com/documentation/mediaintents/responding-to-audio-search-and-playback-requests)
- [Play audio schema](https://developer.apple.com/documentation/appintents/appschema/audiointent/playaudio)

## Automated validation

Public Xcode 27.0 exported the audio playback, podcast-show, and podcast-episode
schema metadata and the AudioSearch query. All 70 selected tests passed on the
iOS 27 simulator; the same built app passed 67 applicable tests on iOS 26.5.
The three schema-only tests are excluded on iOS 26.5. An iOS 18 runtime was not
available on this host, so that oldest supported runtime still needs release QA.
The known StoreKit suites remain excluded; purchase behavior was not changed.

Independent review found loss of donation history on rebuild, delayed consent
cleanup, and stale playback-donation tokens after cancellation. All were fixed,
covered by regressions, and re-reviewed with no remaining blocking findings.

## Latest-podcast correction

Michael verified named-episode playback in Earshot on build 265.973. The apparent
ABC News latest-episode success actually used Apple Podcasts, and the Double Tap
request was rejected for Earshot. That build did not establish successful latest-podcast routing; build 265.975
was subsequently verified below.

The correction returns podcast shows as well as episodes from the AudioSearch
query, recognizes explicit latest/newest episode phrasing, and performs a targeted
lookup for the selected followed show. It rechecks follow state before playback,
preserves position and queue order, and does not refresh the feed. Duplicate show
names remain distinct entities for Siri to disambiguate. Tests include a selected
show whose latest episode is older than 501 episodes from another feed.

Acceptance phrase: “Play the latest episode of Double Tap in Earshot.” Confirm
Earshot—not Apple Podcasts—is playing it, that its episode matches the newest
locally stored entry, and that the previous Earshot episode keeps its position.
If voice routing fails, run Earshot’s Play Latest Episode action in Shortcuts with
Double Tap selected to distinguish routing from the action itself.

The latest-podcast correction passed all 75 selected iOS 27 tests. After the final
follow-state safeguard, all 16 playback and schema-query tests passed again.
Exported app metadata contains one AudioSearch query returning both union cases,
and the Play Latest Podcast action and registered latest-episode phrase.
Independent review found no remaining actionable issues after the final safeguard.

## Silent Shortcuts playback investigation

On build 265.974, the action picker exposed “Play Latest Podcast Episode in
Earshot” even though Michael did not find its App Shortcut tile. Running the
single action with Double Tap selected opened Earshot and completed without an
error, but did not load an episode. Siri's spoken failure remains unverified.

A regression reproduced a matching silent failure: an episode fetched solely
for playback had no visible row retaining it, and the weak reference disappeared
during the cross-device position lookup. Playback now carries the persistent
identifier across that lookup and fetches the surviving episode before starting.
Cancellation and generation checks run before accessing the context. Independent
review prompted a saved-deletion regression and cleared the revised fix.

This correction does not change the separate HTTP-to-HTTPS probe path, whose
weak captures remain an adjacent limitation for episodes using HTTP media.
On build 265.975, Michael confirmed the saved Double Tap shortcut loads and plays
the episode. He also confirmed the spoken latest-episode request plays in Earshot,
including after pausing and locking the phone.

Validation: the fetched-episode regression failed before the fix and passed after
it. The final revision passed all 31 tests in LibraryPlaybackIntentTests and
PlaybackHandoffTests, including saved deletion, pause, and persistence release
while a start is pending. The device build is numbered 265.975.


## Acceptance update — 2026-09-16

Michael enabled listening suggestions and requested no persistent donation
diagnostics. No new diagnostic code or listening-history collection was added.
Review of the existing six passing ListeningDonationsTests confirms coverage of
consent gating, indexed-only eligibility, removal of stale content, relaunch,
in-flight cleanup, and retry after cleanup failure. These use synthetic content
and a fake writer: they verify Earshot's donation logic, not Apple's acceptance
of a donation from Michael's phone or the appearance of a system suggestion.

Remaining release checks include on-device consent-off behavior, saved-position
and queue preservation across show changes, removed-content handling, and the
oldest supported iOS runtime. HTTP probe lifetime remains a separate limitation.
Suggestions can be observed during ordinary use without adding instrumentation.
