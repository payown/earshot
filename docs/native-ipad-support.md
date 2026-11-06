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

The five primary tabs remain tabs. Inbox, Queue, and Downloads retain their
width-driven episode list and detail panes. Library now uses a native
`NavigationSplitView`: subscribed podcasts remain in its sidebar while the
selected show's episode list appears in the detail column. When that detail
column has enough room, it also shows the selected episode's description and
show notes beside the episodes. At intermediate widths, an episode opens
within the detail column with **Back to episodes**, keeping the podcast
sidebar available. The system collapses the split view to compact navigation
for iPhone, closed Duo, and narrow iPad windows. The standard sidebar toggle
allows people to hide or reveal the list.

The Library selection belongs to each `RootView`, and its feed URL is saved in
that window's `SceneStorage`. Notification and Spotlight routes select the show
in the same sidebar rather than pushing a replacement Library screen. The
selected show survives tab switches and width changes; the shared player and
model services remain app-owned. Native list selection provides a persistent
selected appearance and the selected trait to VoiceOver.

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

## Persistent-sidebar follow-up (feature branch, not in build 306)

The sidebar change is currently on `feat/native-ipad-support` after TestFlight
build 306. A Debug simulator build passed. On iPad Pro 11-inch, targeted UI
checks passed for selecting a show while both show rows remain present,
opening an episode, returning to episodes, switching shows, retaining selection
through an Inbox tab switch, and starting playback separately from selection.
The compact Library return flow and episode Play test passed on iPhone 18 Pro;
the compact Library return flow also passed on the closed iPhone Duo simulator.
Existing iPhone seeded launch and Personal Audio navigation checks passed. The
Library filter and tab return check initially exposed a missing compact
toolbar; it passed after the toolbar was attached to the sidebar column.
Existing Queue selection/Play and Downloads filtering/navigation UI checks
passed on iPad Pro. The existing Inbox VoiceOver row-order check passed after
its tab lookup was updated for the iPadOS 27 floating tab bar.
On iPadOS 27.2, an `XCUIVoiceOverService` test enabled VoiceOver, navigated to
the selected podcast, and confirmed the spoken utterance included its name and
selected state. It does not establish focus behavior during live resizing or
on physical hardware. A separate iPad Pro screenshot showed the native sidebar
and adjacent episode list at normal text size; screenshot inspection was not
counted as a VoiceOver interaction test.
On the iPad mini (A20 Pro) simulator, the Library show row remained reachable
and opened its episode screen at the largest accessibility text size.
The Simulator did not rotate the iPad app window when XCTest set
`XCUIDevice.orientation` (its frame remained 834×1210), so landscape and live
window resizing are not marked as tested for this follow-up.

## Manual validation still needed

- Resize an iPad window in Split View, Stage Manager, and iPadOS 26 windowed
  multitasking while an episode is selected and playing. Verify that the
  sidebar, inline episode detail, keyboard, and mini-player remain reachable.
- Open two windows, browse separate tabs and episodes, play from each window,
  close one window, and confirm the surviving window and Lock Screen controls
  reflect the shared player without interrupting audio.
- On a physical iPad, verify VoiceOver reading order and focus during selection,
  window resizing, large Dynamic Type, keyboard navigation, pointer operation,
  AirPlay, background playback, and Control Center commands.
- Confirm iPad App Store screenshots and any release-specific distribution
  requirements before shipping.
