# Siri playback commands

This stage adds two explicit App Shortcuts:

- “Resume listening in Earshot” (also “Continue listening in Earshot”).
- “Play an episode in Earshot”, followed by episode selection, or a phrase with
  the episode parameter.

Both use AudioPlaybackIntent and foreground execution. On a cold launch they wait
for Earshot's existing root-service setup and playback restoration rather than
configuring another player. If setup cannot finish within ten seconds, Siri gets
an actionable error instead of an unbounded wait. Recovery and onboarding must
be resolved in the app first.

Resume works with content indexing off, uses the current/restored episode, and
never toggles into pause. Repeated commands while playback or a handoff is already
requested are no-ops. Playing an entity requires the existing Siri and Search
opt-in and uses the selected episode's current store record, preserving saved
progress and using the existing handoff path without adding/reordering the queue.
A reset or opt-out during resolution is rechecked before playback starts.

This is the explicit-command layer supported by Earshot's iOS 18 baseline. It
does not yet adopt the iOS 27 audio schemas, add arbitrary natural-language media
search, or donate listening interactions. Those require separate validation and,
for action donations, the same opt-out/deletion guarantees as the content index.

## Device acceptance

1. Resume a paused episode through Siri. Confirm the position and speed.
2. Repeat while already playing; playback should continue without restarting.
3. Close Earshot, then resume through Siri. Confirm restored episode and position.
4. Select an episode through Shortcuts and run Play Episode. Check duplicate
   titles across different shows, retained downloads, queue order, and handoff.
5. Disable Siri and Search. Resume should still work; episode selection should
   return the opt-in instruction. A deleted/stale entity must not start another
   episode accidentally.
6. Test an empty player, incomplete onboarding, and recovery. Siri should explain
   what needs attention without changing playback or purchase UI.

## Validation

Xcode 26.6 / Swift 6.3.3: all 57 selected simulator tests passed on iOS 26.5
(LibraryPlaybackIntentTests, LibrarySearchTests, PlaybackSkipIntentTests, and
AppRuntimeTests). Playback tests use a local audio file to verify saved position,
queue preservation, and repeated resume. They also cover startup readiness,
onboarding, cancellation, opt-out, and a reset held during refresh cancellation.
Independent review findings were fixed and re-reviewed with no remaining blockers.
On build 265.972, Michael verified Resume through Siri both from paused playback
and while already playing. The generic Play Episode phrase was rejected before
the app opened. The iOS 27 media integration in [siri-media.md](siri-media.md)
addresses that missing schema/query layer; its device acceptance remains pending.
