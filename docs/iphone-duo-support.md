# iPhone Duo support for Earshot 1.2.6

## Design and SDK

Earshot remains an iPhone app with an iOS 18 minimum deployment target. Its
existing `WindowGroup` owns one `AppRuntime`, which owns the playback engine,
download manager, settings, and store. Resizing a scene does not create another
runtime. This release does not request a second scene or expose a multiwindow
action. If multiwindow becomes a product feature, shared service ownership and
SwiftData coordination need a separate design and test pass.

Apple's iOS 27 SDK enables dynamic window resizing on Duo. The iOS 27.1 SDK
adds full edge-to-edge use and vertical system bars. Earshot uses the native
`TabView`, `NavigationStack`, sheets, `List`, `ScrollView`, and the iOS 26+
`tabViewBottomAccessory`; these own safe-area and bar placement. No custom
reserved-region or hinge-angle code is necessary for the current scrolling
screens. The Now Playing player now changes between stacked and side-by-side
regions from its *available window width*. The same controls and observed
`PlayerService` instance remains app-owned during a width change. On iOS 27.1+
the expanded player uses `ArrangementView` to place its two regions around an
active fold; earlier systems use a standard adaptive stack.

Build 300 adds Apple's iOS 27 native tab-sidebar placement to the existing
`TabView`. `.tabViewStyle(.sidebarAdaptable)` and
`.defaultTabBarPlacement(.sidebar)` let the system show a sidebar when the
current iPhone window has room, including Duo's inner display, and use compact
tabs when it does not. There is no second root navigation tree or device-model
check. On iOS 18–26, Earshot keeps its previous `TabView` behavior.

The iPhone orientation setting now permits both landscape directions as well
as portrait. Apple documents that Duo's inner display ignores the
supported-orientation list, but its outer display honors it. Landscape allows
the outer display's tent pose to use Earshot. This also enables landscape on
conventional iPhones, so compact-height navigation and player tests are part
of the validation matrix. Orientation is never used as a layout signal.

## Audit findings

| Location | Existing behavior and Duo risk | Correction and conventional iPhone impact |
| --- | --- | --- |
| `Earshot/Features/Player/Presentation/NowPlayingScreen.swift` | Fixed 140-point artwork and vertically stacked scroll regions wasted the expanded inner display. | Use two flexible regions when the current window has room; retain the compact transport dock and all actions. Conventional narrow iPhones keep the established layout. |
| `Earshot/App/RootView.swift` | Five native tabs each own a stable `NavigationStack`; iOS 26+ places the mini-player in the native tab accessory. The original Duo build did not offer a sidebar. | Retain the hierarchy and opt the existing `TabView` into system sidebar placement on iOS 27+. The system uses compact tabs when space is limited; older iPhones keep the previous style. |
| `Earshot/App/EarshotApp.swift` | `WindowGroup` creates one app-owned `AppRuntime` holding the player, downloads, and persistence. | Retain the existing service lifetime; no view-owned player is created on resizing. No conventional-iPhone change. |
| Inbox, Queue, Subscriptions, Downloads, Personal Audio, and Settings screens | Native lists, sheets, and navigation with no global display-size or orientation checks. | Retain their existing scrolling and VoiceOver actions. A wholesale split-view conversion would replace stable navigation identity and is deferred pending direct Duo usability evidence. |
| `Earshot/App/Info.plist` | iPhone portrait orientation only restricted the outer Duo display in landscape/tent use. | Add both landscape directions. Conventional iPhones also gain landscape; verify compact-height behavior. |

The source audit searched for `UIScreen.main`, `UIDevice.current.orientation`,
`interfaceOrientation`, `statusBarOrientation`, `userInterfaceIdiom`, size-class
checks, geometry readers, fixed frames, ignored safe areas, safe-area insets,
navigation containers, and custom overlays. No global screen, orientation, or
idiom layout checks were found in app UI. The fixed frames found are control
touch targets or small artwork/chips, rather than screen dimensions.

## Accessibility and continuity

Now Playing keeps one set of control definitions across the layout change. Its
existing labels, values, traits, rotor actions, focus bindings,
and sheet hosts are unchanged. Playback, Queue, and episode selection live in
`AppRuntime`/`PlayerService`, outside the resizing view. The player retains its
scrolling region for artwork and episode information, while the transport dock
keeps play, pause, and seek reachable. At accessibility text sizes in a short
compact window, details remain in the content scroll region rather than taking
a second slice of the limited height. Focus continuity across physical folding
still needs a VoiceOver hardware pass.

## Validation procedure

1. Build and run on a conventional iPhone simulator at iOS 18 or later. Check
   all tabs, Now Playing, Queue, sheets, large Dynamic Type, and background audio.
2. With Xcode 27.1 or later, use the iPhone Duo simulator in Device Hub. Test
   closed, fully open, book, tent, and side-by-side Split View poses, including
   resize in both directions with Now Playing and Queue open.
3. Repeat with VoiceOver enabled. Check swipe order, touch exploration, actions
   rotor, adjustable scrubber, focus after resizing, and each modal dismissal.
4. On physical Duo, verify actual audio continuity, position, Queue, focus,
   asymmetric safe areas, and background playback while another app is active.

## Validation record for 1.2.6 (299)

- Xcode 27.0 Debug simulator build passed before the 27.1-only arrangement was
  added. `PlayerLayoutPolicyTests` and the conventional iPhone landscape
  transport UI test passed on an iPhone 18 Pro simulator running iOS 27.0.
- Xcode 27.2 Release device build, signed archive, and App Store Connect export
  passed with the `ArrangementView` path compiled. The target remains iOS 18.0
  and iPhone only. Xcode 27.2 and the iOS 27.1 simulator runtime were installed
  on this Mac for Duo testing.
- On the **closed iPhone Duo simulator, iOS 27.1**, seven distinct tests passed:
  two layout policy tests; transport reachability; normal and largest
  accessibility text player stability; largest-text player options/touch targets;
  and Queue tab switching and clear confirmation. Screenshots also showed the
  transport and scrubber visible on the outer display at largest text.
- The transport test requested landscape through `XCUIDevice.orientation`, but
  that automation does not rotate a Duo simulator. It verifies controls in the
  closed pose only; conventional iPhone landscape was tested separately.
- The existing player tests initially assumed a symmetric display center and
  tab buttons nested under an accessibility `TabBar`. On Duo, the usable area
  has asymmetric insets and the system exposes vertical navigation differently.
  Their assertions now target the transport center and accessible buttons.
  A tall-screen-only placement assertion is limited to tall windows; all
  reachability and control-stability assertions still run on Duo.
- The open inner display, partial folds, live fold/unfold during playback,
  Split View, and VoiceOver focus transitions remain **unverified**. The older
  Device Hub available to UI automation lacks Duo pose controls; Xcode 27.2's
  Device Hub remains blocked by a first-launch system-components dialog despite
  successful CLI builds and tests. No iOS 18 runtime is installed here.
- Physical iPhone Duo playback and focus continuity have not been tested.
- `xcrun agent skills export` was attempted with Xcode 27.0 and 27.2 but did
  not complete. The manual audit follows the categories in Apple's preparation
  guide; the Apple resizability skill did not provide automated findings.

## TestFlight distribution

Build 1.2.6 (299), built with Xcode 27.2, processed as `VALID` in App Store
Connect. It is `IN_BETA_TESTING` for the **Internal Testing Group**, which
receives all builds. It was explicitly added to **Public Testers** and submitted
for Beta App Review on November 5, 2026; external status is
`WAITING_FOR_BETA_REVIEW` / `WAITING_FOR_REVIEW`. TestFlight notes ask testers to
report pose, iOS version, and inaccessible or clipped controls. No App Store
version was submitted for release. Build ID:
`804aae21-2cf4-4456-9425-a2f77970f80a`.

## Sidebar follow-up, build 300

- Xcode 27.2 Debug build passed with the iOS 27 sidebar API. On the closed Duo
  simulator running iOS 27.1, five launch-tab mapping tests and two navigation
  UI tests passed. The same navigation smoke test passed on an iPhone 17 Pro
  simulator running iOS 26.5, exercising the older-system fallback.
- The inner sidebar, its VoiceOver order and badges, the mini-player in sidebar
  placement, and fold/unfold selection continuity still need direct open-pose
  testing. The Mac's GUI session is locked and the current Xcode Device Hub
  cannot finish first launch until Apple's newer CoreTypes and MobileDevice
  system packages are installed with administrator authentication. No physical
  Duo check has been reported for build 300.
- A signed Release archive and IPA for 1.2.6 (300) exported successfully.
  App Store Connect processed build `770abc89-e99f-4217-90b7-a419e46f8120`
  as valid. It is in beta testing for the Internal Testing Group with automatic
  notifications and the Chapter 107 tester notes. It was added to Public
  Testers, but Apple rejected its beta-review submission because build 299 of
  the same version is still `WAITING_FOR_REVIEW`. Apple permits one build per
  version in beta review at a time. Build 300 was superseded by build 301 after
  the open-pose check below.

## Open-pose follow-up, build 301

The iOS 27.1 Duo simulator was opened, partly folded, and closed with a local
simulator-only `duoctl` helper that posts the fold event and reads the active
display back. This tool is not an Earshot dependency. It uses private simulator
interfaces; use Xcode Device Hub for the standard manual check when the Mac
GUI is unlocked.

- At 180 degrees, the inner display showed a system sidebar with all five
  destinations. Selecting Queue and closing to 0 degrees retained Queue as the
  selected section in the compact vertical bar. Reopening returned to the
  sidebar. Screenshots of the inner and outer displays verified the selection.
- This check exposed an empty native mini-player capsule when no episode was
  loaded, on both poses. The `tabViewBottomAccessory(isEnabled:)` overload,
  available from iOS 26.1, now hides the accessory until the shared player has
  a title. The iOS 26.0 path stays unchanged. A Debug build and screenshots at
  0 and 180 degrees confirmed that the empty capsule is gone.
- On the closed Duo simulator, the build 301 source passed five
  `MiniPlayerVisibilityTests`, five `RootTabLaunchTests`, and two Queue/Library
  navigation UI tests. These automated checks do not assert inner-screen
  VoiceOver behavior.
- The seeded Library launch and tab navigation UI test also passed on an
  iPhone 17 Pro simulator running iOS 26.5, exercising the accessory visibility
  path on a conventional iPhone.
- At `accessibility-extra-extra-extra-large` text size on the open Duo, the
  sidebar labels wrapped and the last item moved below the viewport. Swiping
  the sidebar brought Settings into view; all five destinations remained
  visually reachable. This is not a VoiceOver focus or announcement test.
- At 135 degrees, the inner display showed the sidebar and content without
  clipped essential controls. At 90 degrees, the flat simulator screenshot
  showed the content but did not render sidebar labels or icons. The capture
  cannot establish whether this is a simulator rendering artifact or an
  interactive failure. Check 90-degree navigation in Device Hub and on hardware.
- The simulator's fresh store had no episode, so playback continuity and the
  mini-player while playing were not validated in this open-pose run. The
  sidebar VoiceOver order, focus, badges, and Split View still need direct
  checks. No physical Duo check has been reported. The Mac GUI was unlocked,
  but the newer CoreTypes/MobileDevice packages still need administrator
  authentication before Xcode Device Hub can finish first launch.

Build 301 keeps the iOS 18 deployment target and iPhone-only distribution.
Its signed Release archive and IPA exported successfully. App Store Connect
processed build `8e084a6d-7f67-4b38-83fc-efee6f50ca8d` as valid, with the
Chapter 108 tester notes. The build is `IN_BETA_TESTING` for the Internal
Testing Group with automatic notifications. It is assigned to Public Testers,
but remains `READY_FOR_BETA_SUBMISSION`: Apple refused submission because build
299 still occupies this version's public beta-review slot in
`WAITING_FOR_REVIEW`. Submit build 301 after that review finishes or is
withdrawn. No App Store version was submitted for release.

## Apple references

- [Preparation guide](https://developer.apple.com/iphone-duo/prepare/)
- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [Prepare your app](https://developer.apple.com/videos/play/tech-talks/111461/)
- [Strike a pose](https://developer.apple.com/videos/play/tech-talks/111463/)
- [Multiple displays and scenes](https://developer.apple.com/videos/play/tech-talks/111464/)
