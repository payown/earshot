# Phase Plan Overview

Earshot is built in 11 phases (Phase 0 through Phase 10). Each phase has a clear definition of done and is intended to be a 1-3 week effort for a solo part-time developer.

## How phase docs are written

**Just-in-time.** Detailed phase docs exist for Phase 0 and Phase 1 at project start. As each phase completes, Claude Code writes the next phase's detailed doc based on what was learned in the previous phase. This is governed by `.claude/rules/phase-progression.md`.

The high-level descriptions below are the working scope for each phase until its detailed doc is written. Don't expand scope beyond these bullets without explicit confirmation.

## Phase 0: Project setup, tooling, CI
File: `phase-0-setup.md`. Working Flutter project, no features.

## Phase 1: Core data model, RSS, subscriptions
File: `phase-1-data-model.md`. Subscribe by RSS, view episodes.

## Phase 2: Playback engine, queue, basic UI
- `just_audio` + `audio_service` integration
- Background playback
- Lock screen / Control Center / Android media notification
- Play, pause, skip, seek
- Queue data model and basic queue management UI
- Per-episode playback position persistence

## Phase 3: Accessibility layer, Quick Actions, theme system
- `customSemanticsActions` on all content items
- Quick Action configurator UI in settings
- Theme system: light, dark, high-contrast with full system integration
- Dynamic Type tested across screens
- Reduce Motion respected

## Phase 4: Downloads, Inbox, queue expiration
- Download manager with Wi-Fi-only enforcement
- Auto-download N episodes on subscribe (default 3)
- Auto-download new episodes as they publish
- Inbox flow: new episodes land in Inbox unless podcast is Auto-Queue
- Per-podcast queue age limit with Recently Expired safety net
- Recently Expired list with 7-day retention before file deletion

## Phase 5: Stats and year-in-review
- Listening history tracking with user-controlled retention
- Total time, time saved (silence), time saved (speed)
- Per-podcast breakdowns
- Streaks (opt-in)
- Episodes completed counter
- Year-in-review summary
- CSV export
- All accessible as plain text

## Phase 6: Search, OPML, local audio import, podcast discovery
- Context-aware search with "Search Everywhere" escape hatch
- Apple Podcasts directory search (iTunes Search API)
- Podcast Index integration
- OPML import and export
- Local audio import via iOS Files share sheet and iCloud Drive folder watching
- Android equivalent via Storage Access Framework
- Library section for imported audio

## Phase 7: Polish, performance, beta build
- Onboarding (7 screens)
- Contextual tips system
- Bookmarks and timestamp link sharing
- Chapter support (Podcasting 2.0 and ID3)
- Sleep timer
- Volume boost, mono audio toggle
- Silence trim with time saved tracking
- CarPlay support
- Android Auto support
- Performance profiling and optimization
- Beta crash reporting (Sentry) and analytics (PostHog) integration

## Phase 8: Private alpha
- TestFlight build (iOS)
- Google Play Internal Testing build (Android)
- Recruit 20-50 testers from BITS, ACB, Technically Working audience
- Discord server setup
- Weekly office hours
- Bug triage and fix cycle
- 6-8 weeks duration

## Phase 9: Public beta
- TestFlight public link
- Google Play Open Testing
- Promotion via BITS, ACB Community newsletter, Michael's podcasts, Payown Media website
- Cap at 1,000 testers initially
- 4-6 weeks duration

## Phase 10: App Store and Play Store launch
- App Store Connect listing with screenshots, description, privacy nutrition label
- Google Play Console listing with same content + Data Safety form
- Submission, review, approval
- Launch day coordination: blog post, podcast mentions, social
- Post-launch: monitor crashes, ratings, feedback
- 1,000 download milestone tracking
