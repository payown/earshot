# Phase 0: Project setup, tooling, CI

**Goal:** Have a working Flutter project skeleton with all tooling, lints, and CI in place. No features yet. By the end of this phase, you can `flutter run` and see a "Welcome to Earshot" placeholder screen.

**Estimated duration:** 1-2 weeks (part-time)

## Prerequisites before starting

You already have **Homebrew** and **Claude Code** installed. The remaining setup steps live in `docs/GETTING_STARTED.md` and should be done before working through this phase doc. They are:

- [ ] Flutter SDK installed via Homebrew (`brew install --cask flutter`)
- [ ] CocoaPods installed (`sudo gem install cocoapods`)
- [ ] Xcode installed (App Store)
- [ ] Android Studio installed (`brew install --cask android-studio`) and SDK setup wizard completed
- [ ] Accessibility Agents installed from community-access.org
- [ ] `flutter doctor` returns no critical issues
- [ ] Apple Developer account ($99/year, can wait until ready to publish but easier early)
- [ ] Google Play Developer account ($25 one-time, also can wait)
- [ ] GitHub account / `payownmedia` org for the repository

## Tasks

### 0. Verify environment
- [ ] Confirm `docs/GETTING_STARTED.md` Steps 1 and 2 are complete (Flutter, Xcode, Android Studio, Accessibility Agents installed)
- [ ] `flutter doctor` returns no critical errors
- [ ] `ls ~/.claude/agents/` shows the installed agents

### 1. Create repository
- [ ] Create `github.com/payownmedia/earshot` (public)
- [ ] Add LICENSE (MIT), README.md, CODE_OF_CONDUCT.md, CONTRIBUTING.md, SECURITY.md, .gitignore
- [ ] Add issue and PR templates in `.github/`

### 2. Create Flutter project
- [ ] `flutter create --org media.payown --project-name earshot --platforms ios,android .`
- [ ] Verify it builds and runs on iOS simulator and Android emulator

### 3. Configure analysis and lints
- [ ] Add `very_good_analysis` to dev_dependencies
- [ ] Create `analysis_options.yaml` extending `very_good_analysis`
- [ ] Run `flutter analyze` and resolve all warnings

### 4. Set up project structure
- [ ] Create folders: `lib/core/`, `lib/features/`, `lib/data/`, `test/`, `integration_test/`, `docs/`, `tool/`
- [ ] Move scaffold code into `lib/main.dart` only
- [ ] Add `lib/core/theme/` with placeholder light/dark/high-contrast themes
- [ ] Add `lib/core/constants/` with placeholder spacing tokens

### 5. Add core dependencies
- [ ] `flutter_riverpod` (state management)
- [ ] `just_audio` (audio engine)
- [ ] `audio_service` (background playback)
- [ ] `drift` + `drift_dev` + `sqlite3_flutter_libs` (local storage)
- [ ] `dio` (HTTP)
- [ ] `logging` (structured logging)
- [ ] `package_info_plus` (app version info)
- [ ] `path_provider` (file system paths)

### 6. Dev dependencies
- [ ] `mocktail` (mocking)
- [ ] `build_runner` (codegen for drift)
- [ ] `very_good_analysis`

### 7. CI / GitHub Actions
- [ ] Create `.github/workflows/ci.yml` with:
  - [ ] Lint (`flutter analyze`)
  - [ ] Format check (`dart format --set-exit-if-changed`)
  - [ ] Unit tests (`flutter test`)
  - [ ] iOS build (no signing, debug)
  - [ ] Android build (debug)
- [ ] Branch protection: require CI pass before merge to `main`

### 8. Platform setup
- [ ] iOS: configure bundle ID, display name, permissions in `Info.plist`
  - [ ] Microphone (`NSMicrophoneUsageDescription`): not required for v1
  - [ ] Background modes: audio
  - [ ] iCloud entitlement (for Phase 6, prep now)
- [ ] Android: configure package name in `build.gradle`, permissions in `AndroidManifest.xml`
  - [ ] Internet
  - [ ] Wake lock
  - [ ] Foreground service (for audio_service)
  - [ ] Storage access (for imports)

### 9. Hello world screen
- [ ] Replace default counter app with a screen that says "Welcome to Earshot"
- [ ] Verify the screen text scales with system font size (test by changing iOS Dynamic Type)
- [ ] Verify it has a proper semantic label (test with VoiceOver: should announce "Welcome to Earshot, heading")

### 10. Documentation
- [ ] Write README.md with: project description, mission, build instructions, contribution pointers
- [ ] Write CONTRIBUTING.md with accessibility expectations
- [ ] Write a one-page "Getting Started for Contributors" in `docs/`

## Definition of done

- `flutter run` works on iOS simulator and Android emulator
- `flutter test` passes (the default scaffolded test)
- `flutter analyze` passes with no warnings
- CI passes on a PR opened against `main`
- Hello world screen is screen reader accessible (tested with VoiceOver on simulator)
- All seven repo files (README, LICENSE, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, two templates) are committed
- Accessibility Agents are installed and `ls ~/.claude/agents/` shows the agent files
- A test invocation of the Markdown Scanner agent on `docs/PRD.md` succeeds

## End of phase

When Phase 0 is done, ask Claude Code to write Phase 2's detailed doc. (Phase 1 is already detailed in this starter pack.) Use this prompt:

```
Phase 0 is complete. Walk me through the Definition of Done and confirm. Then capture learnings: what we built, what we learned about Flutter and the tooling, anything we deferred. Update CHANGELOG.md with a "Phase 0 complete" entry. Then propose what should be in Phase 2 based on docs/phases/README.md and what we know now. Don't write the Phase 2 doc yet; let me confirm the plan first.
```

Once you confirm, ask Claude Code to write the Phase 2 doc following `.claude/rules/phase-progression.md`.

## Commands to use during this phase

```bash
# Verify everything is set up
flutter doctor

# Scaffold the Flutter project
flutter create --org media.payown --project-name earshot --platforms ios,android .

# Core dependencies
flutter pub add flutter_riverpod just_audio audio_service drift dio logging package_info_plus path_provider sqlite3_flutter_libs

# Dev dependencies
flutter pub add --dev mocktail build_runner drift_dev very_good_analysis

# Verify the project
flutter analyze
flutter test
flutter run
```

## Claude Code prompts for this phase

Each prompt assumes you've started Claude Code in the project root.

**Prompt 1: scaffold the project**
```
Read docs/PRD.md and CLAUDE.md, then scaffold the Phase 0 project structure as defined in docs/phases/phase-0-setup.md. Create the folder structure, base theme files, constants, and a hello world screen. Don't add any features yet.
```

**Prompt 2: configure lints and analysis**
```
Set up analysis_options.yaml to extend very_good_analysis. Add the dev dependency. Run flutter analyze and fix any warnings in the existing code.
```

**Prompt 3: write the CI workflow**
```
Create .github/workflows/ci.yml that runs flutter analyze, dart format check, flutter test, and debug builds for both iOS and Android. Don't include any signing or upload steps.
```

**Prompt 4: hello world with accessibility**
```
Replace lib/main.dart with a simple home screen that displays "Welcome to Earshot" using Theme.of(context).textTheme.headlineLarge. Ensure it has a proper Semantics wrapper with header: true. Add a widget test that verifies the semantic label is present.
```
