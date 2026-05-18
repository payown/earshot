# Changelog

All notable changes to Earshot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Phase 2 complete — Playback engine, queue, player UI

- Tap any episode to play it — audio streams via `just_audio` with background playback
- Lock screen and Control Center controls wired via `audio_service` (iOS and Android)
- Now-playing bar on subscriptions list and podcast detail screens: artwork, title, skip, play/pause
- Full player screen: large artwork, progress bar with position announced for screen readers, speed selector (0.5x–3.0x), skip controls
- Playback position auto-saves on pause and restores on resume
- Episode marked played at completion
- Queue data model persists across restarts
- Platform configuration: iOS background audio mode, Android foreground service and media permissions
- **Deferred:** Periodic position save while playing (every 10s) — Phase 7 polish
- **Deferred:** VoiceOver/TalkBack manual test — carry into Phase 3

### Phase 1 complete — Core data model, RSS, subscriptions

- Subscribe to any podcast by RSS URL
- RSS parser handles RSS 2.0, iTunes namespace, and Podcasting 2.0 (chapters, transcripts)
- Subscriptions list with podcast artwork, title, and author
- Podcast detail screen with episode list (most recent first)
- Episode rows show title, duration, and relative date
- Pull-to-refresh updates all subscribed feeds
- Subscriptions and episodes persist in SQLite via drift
- All screens accessible: semantic labels on every interactive element, error messages announced via SemanticsService
- **Deferred:** Background feed refresh (every 6 hours) — moved to Phase 4 alongside download manager and background services
- **Deferred:** VoiceOver/TalkBack manual test — carry into Phase 2 PR checklist

### Phase 0 complete — Project setup, tooling, CI

- Flutter 3.41.9 project scaffolded (bundle ID `media.payown.earshot`, iOS + Android)
- Core dependencies added: `flutter_riverpod`, `just_audio`, `audio_service`, `drift`, `dio`, `logging`, `package_info_plus`, `path_provider`, `sqlite3_flutter_libs`
- Dev dependencies added: `mocktail`, `build_runner`, `drift_dev`, `very_good_analysis`
- Feature-first folder structure in place (`lib/core/`, `lib/features/`, `lib/data/`)
- Light, dark, and high-contrast themes wired to system settings
- Spacing token constants defined
- "Welcome to Earshot" screen with accessible `Semantics(header: true)` heading
- Widget test verifying semantic heading label
- CI passing: lint, format check, tests, iOS + Android debug builds
- Accessibility enforcement hooks installed via Community Access agents
- **Deferred:** Manual VoiceOver test on welcome screen (carry into Phase 1 PR checklist)

### Added
- Initial project structure
- Product requirements document (`docs/PRD.md`)
- Phase plans (`docs/phases/`) with just-in-time progression
- Repository hygiene: LICENSE, README, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY
- GitHub Actions CI workflow
- Issue and PR templates
- Phase progression rule (`.claude/rules/phase-progression.md`) for just-in-time phase doc generation
- Integration with Community Access Accessibility Agents (community-access.org)
