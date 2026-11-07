# Build 314: handoff position and VoiceOver Magic Tap

Michael confirmed on physical devices that build 313 no longer closes the iPhone app when the watch opens. He then reported two independent problems: phone-to-watch transfer resumes at least 30 seconds from the phone position, and VoiceOver's two-finger double tap on the watch does not play or pause.

## Handoff position

The watch previously started from a phone state snapshot. The phone continued playing while the watch created and buffered its AVPlayer item; only afterward did the watch ask the phone to pause. The transferred snapshot could therefore be tens of seconds behind the phone's actual pause point. The watch also used AVPlayer's ordinary `seek(to:)`, which Apple documents as allowing an approximate position. Build 314 requests a zero-tolerance seek for the handoff start, reads the phone's final position from the matching pause acknowledgment, and precisely aligns the watch to that position before reporting success. A missing or mismatched pause acknowledgment is reported as a failed handoff. If final alignment fails after the phone stopped, the watch stops and requests a matching-episode phone resume, then reports whether that resume was confirmed. Ordinary scrubbing still uses its previous seek behavior, avoiding the extra decoding cost of precise seeking on every gesture.

Apple reference: [AVPlayer seek with time tolerances](https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:completionhandler:)).

## VoiceOver action

Build 314 adds SwiftUI's `.accessibilityAction(.magicTap)` to the watch Home, Now Playing, and iPhone Control lists. The action follows the playback device represented by Home or Now Playing; iPhone Control explicitly targets the phone. A repeated gesture while a phone command is pending announces a wait message once per request. Existing Play/Pause buttons, spoken labels, rotor actions, and focus order remain available. This is the VoiceOver two-finger touch gesture, not the watch's thumb-and-index-finger Double Tap hand gesture.

Apple references: [AccessibilityActionKind.magicTap](https://developer.apple.com/documentation/swiftui/accessibilityactionkind/magictap), [SwiftUI accessibility actions](https://developer.apple.com/documentation/swiftui/view/accessibilityaction(_:_:)), [VoiceOver Magic Tap behavior](https://developer.apple.com/library/archive/featuredarticles/ViewControllerPGforiPhoneOS/SupportingAccessibility.html), and [Apple Watch VoiceOver gestures](https://support.apple.com/guide/watch/use-voiceover-apdaabc79d3b/watchos).

The required repository accessibility code review found and corrected wrong-device routing on iPhone Control and missing feedback for a second gesture during a pending command. Its final read-only review found no remaining concrete code issue. The actual two-finger gesture, focus propagation, speech timing, and no-double-toggle behavior require physical watch testing with VoiceOver.

## Verification and release gate

The final integrated watchOS 27.0 simulator run passed 26 unit and 4 UI tests with zero failures. A deterministic handoff test covers the source advancing 31.75 seconds after the first snapshot. The final iPhone unit regression passed 2,745 tests with 34 skips and zero failures, using the exclusions below. The iPhone UI regression passed 40 tests with 7 skips and zero failures. Xcode archived and exported 1.2.6 (314) with the iPhone, watch, and widget bundles all at build 314; their archive signatures verify. Xcode reported `Upload succeeded` and `Uploaded package is processing` on November 7. App Store Connect processing, internal group assignment, and test notes still require verification.

The first broad iPhone unit run reported six assertions in two tests: `CloudProjectionCoordinatorTests.testBurstOfRemoteImportNotificationsCoalescesAndStopsCleanly` and `InterruptedLibraryResetRuntimeTests.testSameAccountRecoveryCompletesBeforeNormalLaunch`. Both tests also failed when isolated on the unchanged build 313 branch, so they are pre-existing baseline failures, not caused by this patch. They touch Cloud projection and protected library reset behavior; this watch fix does not change those paths. The passing final regression run excluded those two tests and the two already documented StoreKit simulator failures.

Neither simulator tests nor a successful upload prove audio position or VoiceOver gestures on physical devices. Test the completed 314 internal build in place on both devices before external distribution or merge.
