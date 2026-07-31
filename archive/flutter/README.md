# Archived Flutter implementation

This directory holds the original **Flutter/Dart** implementation of Earshot. It
is kept for reference and history only. It is **not** the app that ships.

Earshot shipped to the App Store on Flutter, then was rewritten in **SwiftUI +
SwiftData** (that rewrite is the live app at the repository root). Once the
SwiftUI version became the product, the Flutter tree was moved here so the
codebase foregrounds the app we actually build and release.

## Why keep it

- It is the full history of how Earshot's features, data model, and
  accessibility patterns were first worked out. A lot of the SwiftUI code was
  ported directly from here, and the SwiftData models still carry comments like
  "Mirrors the Flutter drift `podcast_folders` table."
- Some product docs and hard-won accessibility notes were written against it.
- Nothing about the old implementation is worth losing.

## What's here

| Path | Was at repo root as | What it is |
|---|---|---|
| `lib/` | `lib/` | Flutter/Dart app source |
| `android/` | `android/` | Flutter Android host project |
| `ios/` | `ios/` | Flutter iOS Runner (not the SwiftUI app) |
| `test/` | `test/` | Flutter widget/unit tests |
| `assets/` | `assets/` | Flutter app icon source |
| `pubspec.yaml`, `pubspec.lock` | root | Flutter/Dart dependencies |
| `analysis_options.yaml` | root | Dart lint config (`very_good_analysis`) |
| `tool/` | `tool/` | Flutter build/deploy scripts (`testflight.sh`, icon/launch-image generators, `run-dev.sh`, the Dart pre-commit hook) |
| `github-workflows/` | `.github/workflows/` | The Flutter CI workflows (`ci.yml`, `release.yml`, `security.yml`). Moved out of `.github/workflows/` so GitHub no longer runs them. |
| `claude-rules/` | `.claude/rules/` | The Flutter-specific rule files (`flutter-style.md`, drift `database-migrations.md`) |

## Restoring it

The exact state of the Flutter app as the primary trunk is tagged
**`flutter-final`**. To browse or restore it:

```bash
git checkout flutter-final
```

The full Flutter git history is also intact on the `main`/`swift` history and in
this directory's file history.

## The live app

The shipping SwiftUI + SwiftData app lives at the repository root. See the root
`CLAUDE.md`, `SWIFTUI_PLAN.md`, and `README.md`.
