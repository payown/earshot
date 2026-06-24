
## Swift 6 Review — Track 1: migration cleanup (branch chore/migration-cleanup)

earshot-swift6 gate: PASS. Behavior-preserving extraction of RootView`.task`
 migration logic into `MigrationLaunchCoordinator` (`@MainActor struct`). No new
 concurrency surface introduced.

Mode: built with `SWIFT_VERSION=6 SWIFT_STRICT_CONCURRENCY=complete` overrides
 (project baseline remains Swift 5 / minimal). The changed files
 (MigrationLaunchCoordinator.swift, RootView.swift, FlutterMigrationService.swift)
 produced **zero errors and zero warnings** under Swift 6 strict. The full-target
 Swift 6 build still fails on two PRE-EXISTING issues outside this diff
 (DownloadManager.swift `Episode` non-Sendable across MainActor; SubscriptionRepository
 `RefreshOutcome.backfill` static non-Sendable) — not regressions, owned by the
 broader Layer 2/3 migration, not Track 1.

Key findings:
- Isolation domain UNCHANGED vs the original inline code. The two `Task { }` blocks
  inherit `@MainActor` from the enclosing `@MainActor` context (they are NOT
  `Task.detached` — the doc-comment word "detached" is descriptive, not literal),
  so the body runs on the main actor and only hops at the explicit `await` into
  `SubscriptionImporter` (`@ModelActor`) and `SubscriptionRepository.refreshAll`.
- Captures into the Task are all safe: `subs` is `[FlutterSubscription]` (Sendable
  DTO), `settings`/`importState` are `@MainActor @Observable final class`, `migration`
  is a `@MainActor final class`. No non-Sendable value is sent across an actor boundary.
- @Model boundary clean: no `Podcast`/`Episode` crosses into the `@ModelActor`.
  `importShells` takes Sendable `[FlutterSubscription]`; the actor creates its own
  models on its own context. State overlay (`EpisodeStateImporter`/`QueueImporter`)
  runs entirely on the main `modelContext` inside the `@MainActor` helper.
- Progress callbacks (`onProgress`) are already typed `@MainActor @Sendable` on both
  `importShells` and `refreshAll`; they only call `importState.update` (main-actor).
- `restoreEpisodeState` correctly drops its now-redundant `@MainActor` attribute — it
  is a method on a `@MainActor struct`, so it inherits the isolation.
- `UIKit` import moved from RootView to the coordinator (uses
  `UINotificationFeedbackGenerator`) — correct, no concurrency impact.

Checklist: Sendable PASS; Actor isolation PASS; @Model/@ModelActor boundary PASS;
 AVAudioSession N/A; Combine N/A; nonisolated N/A (none used); Structured concurrency
 PASS (`Task.detached` not used); Global state PASS (none added); Swift 6 build of
 changed files clean PASS.

No blocking issues. No fixes applied. New agents created: none.
