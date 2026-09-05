# Earshot feedback device test

Pre-merge integration: `codex/feedback-integration`. Direct Wi-Fi iPhone
build: 1.2.2 (255), installed and launched on Michael’s iPhone over the paired
local-network connection on September 5, 2026. The first-build VoiceOver checks passed; verification of the player refinement
is pending. The final Release build and signature verification passed.
Michael requested direct device testing first; do not upload to TestFlight.
Do not merge the feature PRs or close #947–#951 until Michael confirms.

## Final anchored Player checklist

The newest local revision keeps version 1.2.2 (255). Identify it by the single
Close / Now Playing / More options header and the playback position plus
transport area fixed below the scrolling artwork and episode details.
Physical VoiceOver verification of this revision is pending.

1. Find Play/Pause and both skips by touch. Change to short and long episodes,
   with and without chapters/artwork, while playing and paused. Start/cancel a
   timer and scroll episode details. The primary controls and slider should
   remain in the same physical area for the same text setting.
2. Explore the slider near its top and bottom edges, then swipe up/down to
   adjust it. It should announce Playback position with the current time, and
   adjacent controls should not take focus. Check that its focus rectangle
   matches the broad touch area. With VoiceOver off, dragging should preview
   the destination time and commit the seek on release.
3. Find Episode artwork in the scrolling content and use its Actions rotor.
   Existing playback/Queue/chapter/episode shortcuts should still work.
4. Swipe through Close, Now Playing and More options. Begin exploring as soon
   as the Player opens; focus should not jump back after a delay.
5. Open and dismiss More options, then Bookmarks through More options. Focus
   should return to More options. Repeat at larger text, and verify all details
   and Show notes remain reachable above the reserved playback area.

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
   Refresh, and Discover remain direct. More options includes sleep timer and
   volume boost; chapters remain directly available. Settings headings group the existing destinations.
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

Final anchored revision (97bef25): signed Release 1.2.2 (255) built, signature
verified, installed and launched over Wi-Fi on the iPhone 17 Pro Max. The running
process was verified. Native unit suite: 2,265 tests, 29 skipped, zero failures;
known StoreKit suites excluded. Seven final SE UI flows passed; two matching
Pro Max iOS 27 layout flows passed. Both screen sizes passed standard and AX5
content-transition stability, slider coordinate edge taps, visible artwork,
header bounds and access to the last scrolling control. Source accessibility
gate PASS. Physical VoiceOver touch accuracy and focus restoration await Michael.
