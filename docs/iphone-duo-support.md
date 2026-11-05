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
| `Earshot/App/RootView.swift` | Five native tabs each own a stable `NavigationStack`; iOS 26+ places the mini-player in the native tab accessory. | Retain this hierarchy so tab and pushed navigation state survives resizing and the system positions the player around vertical bars. No conventional-iPhone change. |
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
- Xcode 27.2 Release device build and signed archive passed with the
  `ArrangementView` path compiled. The target remains iOS 18.0 and iPhone only.
- Two existing player UI regression tests were started but interrupted during
  the Xcode upgrade; they are **not** counted as passed.
- Duo closed, open, partial fold, Split View, vertical bars, and VoiceOver
  transitions remain unverified pending installation of Xcode's required
  CoreSimulator system package and an iOS 27.1+ Duo runtime. The Mac presents
  a protected administrator authorization prompt for that package.
- Physical iPhone Duo playback and focus continuity have not been tested.
- `xcrun agent skills export` was attempted with Xcode 27.0 and 27.2 but did
  not complete while the system component setup was blocked. The manual audit
  follows the same categories described in Apple's preparation guide.

These entries must be updated if the simulator gate is resolved before release.

## Apple references

- [Preparation guide](https://developer.apple.com/iphone-duo/prepare/)
- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [Prepare your app](https://developer.apple.com/videos/play/tech-talks/111461/)
- [Strike a pose](https://developer.apple.com/videos/play/tech-talks/111463/)
- [Multiple displays and scenes](https://developer.apple.com/videos/play/tech-talks/111464/)
