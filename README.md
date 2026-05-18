# Earshot

A podcast player built for the way you listen.

Earshot is an accessibility-first podcast player developed by [Payown Media LLC](https://payown.media/). It's free, open source, and built with deep care for screen reader users.

## Why Earshot

Most podcast apps are accessible enough to use, but none are designed *for* screen reader users. Earshot is. It's built by someone who uses VoiceOver, TalkBack, and JAWS daily, with input from the BITS (Blind Information Technology Solutions) and ACB (American Council of the Blind) communities.

The two features that set Earshot apart:

- **Quick Actions** you configure. Pick which actions appear on each content type, and in what order. Play now, add to queue, open show notes, whatever fits your workflow.
- **Queue expiration** per podcast. News show? Episodes auto-expire after 2 days. Weekly long-form? Set it to 2 weeks. Or off entirely.

Plus comprehensive listening stats that show you how much time you've spent and how much time silence trimming saved you.

## Status

Pre-development. The product requirements doc lives in [`docs/PRD.md`](docs/PRD.md). The phased build plan lives in [`docs/phases/`](docs/phases/).

## Platforms

- iOS 16+
- Android 10 (API 29)+
- iOS launches first, Android within 6 months.

## Tech stack

- Flutter (latest stable)
- Dart
- Riverpod for state management
- `just_audio` and `audio_service` for audio
- `drift` for local SQLite storage

## Building

Prerequisites:
- Flutter SDK (latest stable)
- Xcode (for iOS)
- Android Studio (for Android)
- CocoaPods (`sudo gem install cocoapods`)

```bash
git clone https://github.com/payownmedia/earshot.git
cd earshot
flutter pub get
flutter run
```

To build for iOS device, you'll need a free Apple ID configured in Xcode. For the App Store, an Apple Developer account is required.

## Contributing

Contributions welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

**Important:** Accessibility is non-negotiable. PRs that regress accessibility will not be merged. Every UI change requires testing with VoiceOver or TalkBack and notes in the PR description.

## License

[MIT](LICENSE). Use it, fork it, learn from it.

## Acknowledgements

Earshot exists because of the people who taught me what accessible software actually means. Thanks to:

- **BITS** (Blind Information Technology Solutions), an affiliate of the American Council of the Blind
- The broader **ACB community**
- Every beta tester who shaped the app

## Contact

- Project: [github.com/payownmedia/earshot](https://github.com/payownmedia/earshot)
- Maintainer: Michael Babcock (michael@payown.media)
- Payown Media: [payown.media](https://payown.media)
