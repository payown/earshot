# Phase 8: Private alpha

**Goal:** The app is in the hands of 20-50 carefully selected testers via TestFlight and Google Play Internal Testing.

**Estimated duration:** 6-8 weeks (includes the testing period itself)

## Prerequisites

- Phase 7 complete
- Active Apple Developer Program membership ($99/year)
- Active Google Play Developer account ($25 one-time)
- App Store Connect app record created for `media.payown.earshot`
- Google Play Console app record created

## Tasks

### 1. App icon
- [ ] Final app icon designed (or use a placeholder)
- [ ] iOS: replace `ios/Runner/Assets.xcassets/AppIcon.appiconset/` with production icons
- [ ] Android: replace `android/app/src/main/res/mipmap-*/ic_launcher.png`
- [ ] Icon must be accessible: distinctive shape + color, not text-only

### 2. Version and build number
- [ ] Set version to `0.1.0` in `pubspec.yaml`
- [ ] Build number to `1`
- [ ] Confirm iOS `FLUTTER_BUILD_NAME` and `FLUTTER_BUILD_NUMBER` flow correctly

### 3. Add real Sentry DSN and PostHog key
- [ ] Sign up at sentry.io, create Flutter project, get DSN
- [ ] Sign up at posthog.com (cloud), create project, get API key
- [ ] Add to CI/CD as secrets — pass via `--dart-define` at build time:
  ```
  flutter build ipa --dart-define=SENTRY_DSN=https://...@sentry.io/...
  ```
- [ ] Verify opt-out toggles actually disable reporting

### 4. iOS build and TestFlight
- [ ] In Xcode: set team, bundle ID `media.payown.earshot`, signing
- [ ] Archive build: `flutter build ipa`
- [ ] Upload to App Store Connect via Xcode Organizer or Transporter
- [ ] Create TestFlight build group "Private Alpha"
- [ ] Add internal testers (up to 25 without App Review)
- [ ] Write TestFlight test notes (what to test, known issues, how to report)

### 5. Android build and Play Internal Testing
- [ ] Generate signing keystore (keep this secret, back it up)
- [ ] Configure `android/key.properties` (gitignored) and `build.gradle.kts`
- [ ] Build: `flutter build appbundle --release`
- [ ] Upload to Play Console → Internal Testing track
- [ ] Add tester email addresses
- [ ] Write release notes

### 6. Recruit testers
Target mix (20-50 total):
- BITS members (blind, VoiceOver/TalkBack users) — primary audience
- ACB Community Builder listeners
- Technically Working listeners (Michael's podcast)
- Our Perspective listeners (Michael's podcast)
- Sighted accessibility professionals (a11y consultants, QA testers)
- Mix of iOS and Android users

Contact channels:
- BITS email list
- ACB Community newsletter
- Direct messages to known power podcast users
- Michael's podcast outro

### 7. Feedback structure
- [ ] Set up Discord server for Earshot beta
  - Channels: announcements, general-feedback, bugs, accessibility, feature-requests, ios-beta, android-beta
- [ ] In-app feedback: Settings → Send Feedback (email to beta@payown.media)
- [ ] Weekly office hours (Zoom audio, 30 min)
- [ ] Commit: respond to all feedback within 48 hours

### 8. Bug triage during alpha
- [ ] Triage incoming bugs into GitHub Issues with labels: `bug`, `accessibility`, `enhancement`
- [ ] Accessibility regressions get priority label `critical-a11y` and block next release
- [ ] Weekly release cadence during alpha: fix critical bugs, upload new build
- [ ] Track: crash-free session rate (target 99.5%+), accessibility issues filed and resolved

## What I (Claude Code) can help with

- App icon creation (placeholder or production SVG → PNG pipeline)
- CI/CD release workflow in `.github/workflows/`
- Signing configuration and secrets setup instructions
- TestFlight and Play Store metadata files
- Bug triage and fix cycles
- Accessibility regression tests
- Building and testing locally

## What you (Michael) need to do manually

- Upload to App Store Connect / Play Console (requires your credentials)
- Apple Developer / Google Play account setup
- Final icon design (design decision)
- Recruiting testers (relationship-based)
- Running office hours

## Commands to use during this phase

```bash
# Set version
# In pubspec.yaml: version: 0.1.0+1

# iOS build for TestFlight
flutter build ipa \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=POSTHOG_API_KEY=$POSTHOG_API_KEY

# Android release build
flutter build appbundle \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=POSTHOG_API_KEY=$POSTHOG_API_KEY

# Run all tests before every build
flutter test && flutter analyze
```

## Claude Code prompts for this phase

**Prompt 1: release CI workflow**
```
Create .github/workflows/release.yml that builds iOS and Android release artifacts when a tag matching v*.*.* is pushed. Pass SENTRY_DSN and POSTHOG_API_KEY as --dart-define from GitHub secrets. The workflow should run tests and analyze first, then build. It should not sign or upload — just produce the artifacts for manual upload.
```

**Prompt 2: bug fix cycle**
```
We have incoming alpha feedback. Here are the reported issues: [paste issues]. Triage each one: is it a crash, accessibility regression, or feature request? For accessibility regressions, fix them first. For crashes, fix them next. Write a concise fix for each and make sure tests pass before creating a PR.
```

**Prompt 3: beta release notes**
```
Prepare release notes for TestFlight build [number]. What changed since the last build: [paste git log]. Write in plain language, mentioning what was fixed and what testers should specifically verify. Keep it under 200 words.
```
