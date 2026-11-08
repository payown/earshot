# Earshot

Earshot is a native SwiftUI podcast app for iPhone, iPhone Duo, and iPad. It
uses one iOS application target and an iOS 18 minimum deployment target.
Inbox, Queue, Library, Downloads, and Settings remain primary tabs. Content
within a tab adapts to the available window width; iPad also supports
multiple windows with shared library data and playback.

The app includes subscriptions, podcast search, show notes, downloads, OPML
import, a customizable episode Actions rotor, background audio, and system
media controls. Its interface and testing prioritize VoiceOver.

## Build

Use Xcode 27.0 or later with Swift 6.4 and XcodeGen 2.46.0. The project source
of truth is `project.yml`; run `xcodegen` after changing it. There are no
third-party Swift dependencies.

```bash
xcodegen
xcodebuild build -project Earshot.xcodeproj -scheme Earshot \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

The bundle identifier is `media.payown.earshot`. Device builds use the
repository's existing automatic signing setup.

## Adaptive device support

- [iPhone Duo design and validation](docs/iphone-duo-support.md)
- [Native iPad design and validation](docs/native-ipad-support.md)

The shared layout responds to content width and Dynamic Type. Duo-specific
fold behavior stays isolated to the player arrangement. Each iPad scene owns
its tab and selection state; the app owns one player, download service, and
model container. The iPad document records simulator coverage and the physical
device checks still required for windowing, input devices, and VoiceOver.
