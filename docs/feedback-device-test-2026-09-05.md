# Earshot feedback device test

Pre-merge integration: `codex/feedback-integration`. Direct Wi-Fi iPhone
build: 1.2.2 (255), installed and launched on Michael’s iPhone over the paired
local-network connection on September 5, 2026. The first-build VoiceOver checks passed; verification of the player refinement
is pending. The final Release build and signature verification passed.
Michael requested direct device testing first; do not upload to TestFlight.
Do not merge the feature PRs or close #947–#951 until Michael confirms.

## Player refinement checklist

Michael passed the original checks below on the first Wi-Fi build. This second
local revision keeps version 1.2.2 (255); identify it by the single More options
button and larger transport controls. The refinement was installed over Wi-Fi on September 5, 2026.

1. Open Now Playing, then More options. There should be one options opener,
   Episode actions followed by Playback settings, and no duplicate chapter
   destination. Queue commands remain flat, and chapters remain direct.
2. Open Bookmarks, then close it. Focus should return to More options. Close
   More options with Done and check the same return point.
3. Explore Play/Pause and both Skip buttons by touch, including near their
   edges. Each should announce and activate only its own control. Check speed,
   More options, Close, and +5 min while a countdown timer is running.
4. Repeat at larger text, scrolling as needed. Check chapter access, spacing,
   and the existing artwork/Skip rotor actions and hints.

## Original VoiceOver checklist (passed on iPhone)

1. **Names:** Library, open a followed show, Podcast settings, Rename podcast.
   Save a short name. Hear it in Library, Queue, and Now Playing. Search for
   both the new and publisher names. Refresh and reopen Earshot; the override
   should remain. Restore original name; the current publisher name returns.
   Cancel should discard edits, and blank names should not save. Cross-device
   iCloud verification needs matching signing environments; this development-
   signed local build does not establish production iCloud sync behavior.
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
   Refresh, and Discover remain direct. More options includes sleep timer,
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

## Native validation

Full integrated unit suite: 2,264 tests, 29 skips, zero failures; known
StoreKit suites excluded as required. Final playback/media follow-up: 73
passed. Name identity assertion passed. All five selected UI flows passed
across the initial run and corrected Queue-clear rerun. The initial clear
dialog lacked a reachable Cancel; the final native alert fixes that failure.
Required source accessibility review passed, including the final alert.

Draft PRs: #952 names, #953 hints, #954 Queue navigation, #955 wrapping,
#956 navigation cleanup. Physical VoiceOver is not claimed as verified by these native checks.

Player refinement validation: 105 selected native unit tests passed, five
existing UI flows passed, and the final geometry/near-edge activation/Bookmarks
flows passed at normal and AX5 text on iPhone SE and iPhone 17 Pro. Required
source accessibility review passed. The signed Release build passed and was
installed locally; no TestFlight upload.
