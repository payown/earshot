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
navigation and the full player at the largest accessibility text size. After
correcting an ambiguous XCTest tab query, the New Window UI test passed and
observed a second app window. On iPhone 18 Pro, 68 focused unit tests and the
episode-selection and playback UI test passed.
The same episode-selection and playback UI test passed on the iOS 27.1 Duo
simulator. These simulator runs do not cover a physical Duo hinge transition.

The build still emits pre-existing warnings in `EpisodeRow` and App Intents code.
The iPad test results include an existing system warning about synchronous
audio-session activation; no test failed on that warning.

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
