# Earshot feedback device test

Pre-merge integration: `codex/feedback-integration`. Intended internal TestFlight
build: 1.2.2 (256). Installation and physical VoiceOver verification are pending.
Do not merge the feature PRs or close #947–#951 until Michael confirms.

## Short VoiceOver checklist

1. **Names:** Library, open a followed show, Podcast settings, Rename podcast.
   Save a short name. Hear it in Library, Queue, and Now Playing. Search for
   both the new and publisher names. Refresh and reopen Earshot; the override
   should remain. Restore original name; the current publisher name returns.
   Cancel should discard edits, and blank names should not save. If using two
   synced devices, check both rename and restore arrive on the other device.
2. **Player actions:** With a few queued episodes, open Now Playing. On Skip
   forward, use Next in Queue; on Skip back, use Previous in Queue. The skipped
   episode stays unplayed in the same Queue position and resumes at its saved
   place. Neither action wraps. Mark as played and next in Queue removes only
   the current episode. Artwork and Episode actions offer the same commands.
   Normal double-tap still skips the configured number of seconds. Repeat with
   hints on and off, with and without chapters, and while paused.
3. **Wrapping:** Settings, Playback, Wrap Queue to remaining episodes starts
   off. Turn it on, start the last displayed Queue episode, and let it finish.
   Playback should go to the first remaining unplayed episode, using the visible
   group order. Completed episodes must not return. Repeat with group/episode
   auto-advance disabled, Stop after this episode, and a sleep timer. Those
   stops take precedence; a countdown keeps running across automatic advances.
   Manual Previous/Next still do not wrap and keep their timer-cancel behavior.
4. **Navigation:** Library options contains Sort and Select; Search, Folders,
   Refresh, and Discover remain direct. Player options opens sleep timer,
   volume boost, and chapters. Settings headings group the existing destinations.
   Existing episode and podcast rotor actions should still be available.
5. **Clear Queue:** Queue options, Clear queue explains the whole Queue and
   whether downloaded audio will be deleted. Cancel must leave everything
   intact. Confirm only with a Queue you intend to clear. Success should be
   announced after saving and focus should return to the Queue heading.

Check swipe navigation and Explore by Touch, focus after sheets and menus
close, largest Dynamic Type if useful, and responsiveness during playback.
Report any missing actions, unexpected marks/removals, lost listening places,
unclear speech, or new delay. Simulator/source checks do not establish these
physical-device results.

## Scope and data policy

Custom names use existing private-iCloud setting records; there is no model or
CloudKit schema change. Publisher metadata remains separate and shared exports
retain publisher names. Restore is an explicit cleared preference. Queue wrap
is opt-in and does not recreate consumed episodes. Folder-wide oldest-first
runs (#944) remain unimplemented and independent of normal Queue navigation.
