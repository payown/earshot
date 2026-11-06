# Native iPad support

Earshot uses one iOS application target for iPhone, iPhone Duo, and iPad. The
minimum deployment target remains iOS 18. The project enables both device
families and the existing iPad portrait and landscape orientation masks. The
launch screen and background audio modes remain in place.

`WindowGroup(id: "earshot-main")` creates independent `RootView` instances for
each window. Tab selection and navigation state live in each view; `SceneStorage`
restores the selected tab and Library podcast for that window. The `App` owns one `AppRuntime`, so
all windows use the same `ModelContainer`, download service, and `PlayerService`.
Settings offers **Open another Earshot window** when the system supports it.
The full-player sheet and external navigation requests are claimed by the
focused window. Search indexing belongs to the process, so opening or closing
a scene does not restart it. Tab badges update in every scene.

The five primary tabs remain tabs. The Duo width policy supplies list and detail
panes in Inbox, Queue, Library, Downloads, and episode lists when the current
window is wide enough. Narrow windows use the established single-column flow.
Library search now keeps results visible beside the selected podcast or episode
on wide windows. A selected search detail moves to a sheet if the window narrows.
Descriptions and show notes have a readable maximum width in the detail pane.
The full player retains its shared responsive regions and audio engine.

## Simulator validation

With Xcode 27.2, the app built for iPad Pro 11-inch and iPhone 18 Pro simulators.
Five targeted layout and UI tests passed on iPad Pro 11-inch. Two additional UI
tests passed on iPad mini, covering compact episode detail and landscape player
control reachability. Another iPad Pro run passed real VoiceOver episode-row
navigation and the full player at the largest accessibility text size. The New
Window action appears in iPad Settings. XCTest exposed an auxiliary UIKit
window as a second `Window`, so its window count cannot establish that a second
Earshot scene opened. Independent scene behavior requires a device check. On
iPhone 18 Pro, 68 focused unit tests and the
episode-selection and playback UI test passed.
The same episode-selection and playback UI test passed on the iOS 27.1 Duo
simulator. These simulator runs do not cover a physical Duo hinge transition.

The build still emits pre-existing warnings in `EpisodeRow` and App Intents code.
The iPad test results include an existing system warning about synchronous
audio-session activation; no test failed on that warning.

The follow-up window-routing changes built with Xcode 27.2. Playback and the
New Window action were rerun as targeted iPad UI tests. These checks do not
prove independent navigation or shared playback across two visible scenes.
Build 1.2.6 (306) archived for iOS Release, exported as a signed IPA, and was
verified to contain both device families, an iOS 18 minimum, iPad portrait and
landscape orientation support, and the multiple-scenes declaration. It was
processed as `VALID` in App Store Connect and is `IN_BETA_TESTING` for the
Internal Testing Group. Its build ID is
`4f6b6cc8-56e0-4d0b-afaf-bf92f43ebf09`. It has not been submitted to the
Public Testers group or for an App Store release. The app and its older
iPhone/Duo paths still require the physical-device checks below.

## Manual validation still needed

- Resize an iPad window in Split View, Stage Manager, and iPadOS 26 windowed
  multitasking while an episode is selected and playing. Verify that the detail
  sheet transition, keyboard, and mini-player remain reachable.
- Open two windows, browse separate tabs and episodes, play from each window,
  close one window, and confirm the surviving window and Lock Screen controls
  reflect the shared player without interrupting audio.
- On a physical iPad, verify VoiceOver reading order and focus during selection,
  window resizing, large Dynamic Type, keyboard navigation, pointer operation,
  AirPlay, background playback, and Control Center commands.
- Confirm iPad App Store screenshots and any release-specific distribution
  requirements before shipping.
