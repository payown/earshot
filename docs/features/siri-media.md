# Siri media search and listening suggestions

This stage builds with public Xcode 27.0 (27A266a), Swift 6.4, and XcodeGen
2.46.0. The deployment minimum remains iOS 18. The new schemas and MediaIntents
query are available only on iOS 27; existing Spotlight entities and Resume
shortcuts remain available on earlier supported systems.

## Playback

Siri can query Earshot's opted-in searchable selection through AudioSearch and
receive podcast episode entities conforming to Apple's podcastEpisode schema.
The playAudio action accepts a union of episode and podcast-show entities. A
show selection starts its newest episode within the searchable selection. All
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
