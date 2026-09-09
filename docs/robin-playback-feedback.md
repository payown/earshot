# Robin's playback requests

This change adds three features for the next release. It does not change the
version or build number, or publish an App Store or TestFlight build.

## Custom playback speed

Open Playback Speed from the full player. With VoiceOver, double-tap Playback
speed or use its “Open speed options” action. The control includes a hint about
double-tapping to choose a custom speed; flicking up or down still adjusts it. Enter a value in Custom playback
speed and choose Apply custom speed. The selected scope applies: this podcast or
all podcasts. The allowed range is 0.5×–5×, with up to two decimal places.
Both the local decimal separator and a period are accepted.

Invalid entries show an error without changing playback. Quick choices and the
0.1× stepper remain available. Stored and handed-off speeds preserve hundredths,
including the existing 1.25× and 1.75× shortcuts. Opening or resetting the picker
no longer triggers its stepper's write-back observer.

## Reset sleep timer on interaction

The More options sheet has an optional Reset sleep timer on interaction switch.
It defaults to off and is saved on this device. When enabled, a running countdown
restarts from the selected duration after app touches, scrolling, hardware key
presses, text editing, or accessibility focus movement. Manually starting another
episode also restarts that countdown. Automatic episode advancement does not.

Resets are silent. They do not change VoiceOver focus. Touch observation covers
sheets through the scene's window and neither recognizes nor blocks gestures.
The observer ignores input while the scene is inactive or in the background.
An expired or cancelled timer is never restarted. End-of-episode behavior is
unchanged. The next interaction replaces any manually added extension with the
selected duration, as explained beside the switch.

UIKit's accessibility focus notification does not identify whether a focus move
was user-directed or automatic. A foreground automatic focus move can therefore
also restart the countdown. Background playback and timer ticks are not activity.

## Mini-player announcement

The title button says “Mini player, [episode title], [podcast name]” in one
VoiceOver stop. Its button trait, full-player hint, optional sleep-timer value,
and surrounding transport buttons retain their existing behavior.

## Validation

Xcode 26.6 / Swift 6.3.3, iOS 26.5 simulator: 132 selected unit tests and four
UI tests passed. The two known failing StoreKit suites were excluded. An initial
unsigned simulator run failed at launch; the signed, serial rerun passed. The
timer UI test was corrected to scroll controls fully into view before tapping.

Automated checks cover exact-speed parsing, preserving custom rates, saved
scope, timer preference persistence, countdown reset and expiry, cancellation,
manual episode changes, and end-of-episode behavior. UI checks cover entering
0.98×, opening the full player through the mini player, and existing player
controls at normal and largest text sizes.

Before release, check on an iPhone with VoiceOver:

1. Enter 0.98× for a podcast, reopen the picker, and confirm the rate remains.
2. Flick from the last Queue or Inbox row onto the mini player. Confirm the
   prefix, title, and podcast are one stop and the controls still follow it.
3. Enable reset and start a five-minute timer. After part of the countdown,
   navigate with VoiceOver, activate a control, adjust a value, scroll a list,
   and type in a sheet. Confirm each interaction restarts the countdown without
   interrupting speech or changing navigation.
4. Lock the phone and let the timer finish. Confirm playback stops normally.
5. Disable reset and confirm the original countdown and episode-switch behavior.
6. With reset enabled, confirm End of episode still stops at the episode boundary.
