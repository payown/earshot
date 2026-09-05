# Earshot feedback device test

Pre-merge integration: `codex/feedback-integration`. Direct Wi-Fi iPhone
build: 1.2.2 (255), installed and launched on Michael’s iPhone over the paired
local-network connection on September 5, 2026. The first-build VoiceOver checks passed; verification of the player refinement
is pending. The final Release build and signature verification passed.
Michael requested direct device testing first; do not upload to TestFlight.
Do not merge the feature PRs or close #947–#951 until Michael confirms.

## Final bottom-row Player checklist

The latest local revision keeps version 1.2.2 (255). The anchored area now reads
Playback position, Skip back / Play-Pause / Skip forward, then AirPlay (audio
destination) and Show notes side by side. The bottom row raises transport while
preserving its physical position for a given screen and text setting.

1. Explore playback position, then move down to Play/Pause and the skips. Check
   whether they feel comfortably placed; their enlarged targets should remain
   separate. The position slider must stay above transport.
2. Find AirPlay and Show notes below transport. Open each, then return. AirPlay
   should present the native destination picker. Actual destination selection
   is a physical-device check; the simulator did not expose that system sheet.
3. Compare episodes with and without notes. Show notes must stay in place and
   announce its unavailable/disabled state when absent. Transport must not move.
4. Change long/short episodes, wait for chapters/artwork, and start/cancel a timer.
   Scroll all details and repeat at larger text. Controls should stay anchored,
   notes should wrap without clipping, and the Home indicator should stay clear.
5. Confirm artwork and its Actions remain reachable, and returning from More
   options still restores focus. No delayed opening request should steal focus.

Measured simulator bounds and native test results are documented below. They do
not establish physical VoiceOver touch accuracy, focus, or comfort.

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

Bottom-row revision (app code 6817eea): signed Release 1.2.2 (255) installed and
launched over Wi-Fi; running process verified. Required accessibility source
review passed. Focused native checks: 168 playback/Queue tests and 15 sleep-timer
tests passed. Eight UI checks passed across SE and Pro Max, including standard
and AX5 geometry, notes becoming disabled without moving controls, slider edge
taps, scrolling to the last timer control, Show notes activation, native AirPlay
button bounds, and existing More options/Bookmarks flows. An initial scroll
assertion selected the mini-player behind the sheet; the corrected query scopes
to the full Player. The native destination sheet wasn't exposed in the simulator;
physical destination selection remains unverified.

Measured standard-text targets: slider 56pt high, skips 64×64, Play/Pause 80×80,
AirPlay 64×56 and notes 56pt high. Notes wraps to about 125pt high at AX5 while
remaining beside AirPlay. Pro Max standard-text Play/Pause center is 806pt from
the screen top; bottom-row buttons end at 914pt on the 956pt screen, clear of the
Home indicator. Episode-content changes left measured y-positions/heights
unchanged within the 1pt test tolerance. These are simulator measurements, not
Michael's physical VoiceOver results.
