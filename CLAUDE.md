# CLAUDE.md - Earshot Project Memory

This file provides essential project context to Claude Code at the start of every session. Keep it under 200 lines so it loads efficiently.

## Project identity

**Earshot** is an accessibility-first podcast player for **iOS/iPadOS**, built in **SwiftUI + SwiftData**. It is open source (MIT) and a Payown Media LLC project with deep connection to BITS and the ACB community. Freemium: free up to 10 podcast subscriptions, paid tier unlocks unlimited (see rule 5).

Earshot originally shipped on Flutter, then was rewritten in SwiftUI. **The SwiftUI app is the one and only product; it lives at the repository root.** The retired Flutter implementation is kept for reference under `archive/flutter/` and tagged `flutter-final`. Do not build on the Flutter tree.

The SwiftUI implementation plan and decision log live in `SWIFTUI_PLAN.md`. Agent guidance lives in `AGENTS.md`. Read them for context.

## Owner and voice

- **Owner:** Michael Babcock, Payown Media LLC
- **Contact:** michael@payown.media
- **Brand voice:** Direct, conversational, friendly. Short paragraphs. No em dashes. No corporate words ("instrumental," "crucial," "game changer," "mastering," "fulfilling"). Contractions are fine. First person where appropriate.
- **Signs as:** Michael

## Non-negotiable rules

1. **Never work directly on main.** Every fix, feature, or change gets its own branch. Main must always be stable and deployable.
2. **Accessibility is the highest priority.** Michael is blind and uses VoiceOver. Every UI element needs a correct accessibility label, value, trait, and focus behavior. Every PR that touches UI includes VoiceOver testing notes. Code that regresses accessibility is not merged.
3. **Follow system settings.** Never override the user's theme, font size, motion, or contrast preferences. Earshot reads from the system, never imposes.
4. **Zero data collection.** Earshot ships no telemetry SDK, no crash reporter, no analytics, and no third-party dependencies at all. It collects no data: no advertising IDs, no device identifiers, no third-party trackers. Listening history stays on device and is user-controlled. The App Store privacy nutrition label is "Data Not Collected" for every category except Purchases (StoreKit transaction/entitlement state, App Functionality only, not linked to identity, not used for tracking).
5. **Freemium.** Free tier: up to 10 podcast subscriptions. Paid unlock (unlimited podcasts), "Earshot Plus": $2.99/month, $19.99/year, or $49.99 one-time (lifetime), via App Store IAP/subscription. An in-app tip jar (App Store IAP, presets $1.99/$4.99/$9.99) is available to both free and paid users regardless of tier. No ads, no third-party trackers, no ad-based monetization of any kind. All code public on GitHub under MIT.
6. **GHCP prompts always in code blocks** when generating them.
7. **Phase progression follows `.claude/rules/phase-progression.md`.** When a phase completes, verify the Definition of Done, capture learnings, and write the next phase's detailed doc before starting work on it.

## Accessibility agents

Agent files are installed at `~/.claude/agents/`.

**Invoke via the Agent tool** using just the agent name:

| When | Agent |
|------|-------|
| Any SwiftUI UI change (required gate) | `earshot-accessibility` |
| Generic mobile/iOS a11y review | `mobile-accessibility` |
| Full audit / unknown scope | `accessibility-lead` |
| Docs / markdown | `markdown-a11y-assistant` |

**Rule:** Run `earshot-accessibility` on every PR that touches SwiftUI views before merging. Do not skip this even for "small" changes. It reviews VoiceOver labels/values/traits, focus order, the actions rotor, Announcer timing, Dynamic Type, touch targets, contrast, and motion.

## Tech stack

- **UI:** SwiftUI (iOS 18.0 deployment target; iPhone for 1.0, iPad tracked for 1.1)
- **Language:** Swift 6 language mode, **complete** strict concurrency
- **Local storage:** SwiftData (`@Model`), versioned schema + explicit migration plan
- **Audio/media:** AVFoundation (playback, chapters, downloads)
- **Monetization:** StoreKit 2 (IAP subscription + lifetime unlock + tip jar)
- **Logging:** `AppLog` (an `os.Logger` wrapper — `AppLog.data`, `AppLog.networking`, etc.). **No `print()`.**
- **Project generation:** XcodeGen (`project.yml` is the source of truth)
- **Testing:** XCTest (`EarshotTests`)
- **Dependencies:** none. There are **no third-party Swift packages**. Do not add one without confirmation.
- **Toolchain:** Xcode 26.6, Swift 6.3.x, XcodeGen. CI runs on a self-hosted Apple Silicon Mac.

## Architecture conventions

- **Feature-first:** `Earshot/Features/<feature>/{Data,Domain,Presentation}` (e.g. `Earshot/Features/Folders/...`).
- **Shared code:** `Earshot/Core/` (UI helpers, networking, theme). Cross-feature data/models in `Earshot/Data/` (`Models/`, `Persistence/`).
- **No business logic in views.** Views are presentational; logic lives in `@Observable` view models / services / `Domain` types.
- **Colors and text from the system.** Use semantic `Color`/`Font` and Dynamic Type. Never hardcode raw font sizes or fixed colors that fight the user's theme.
- **`AppLog`, not `print()`.**
- **Concurrency:** respect Swift 6 actor isolation and `Sendable`. `@MainActor` for UI; keep DB/network work off the main actor.

## SwiftData migrations (read before any model change)

The data layer is the highest-risk surface: TestFlight testers carry real on-device data across builds, and a broken migration can dead-end the app on launch (this happened once historically). Follow `.claude/rules/database-migrations.md`.

- Persistence lives in `Earshot/Data/Persistence/`: `EarshotSchema.swift` (frozen `VersionedSchema` snapshots V2-V5), `EarshotSchemaV1.swift`, `StoreMigration.swift` (the migration plan + the manual V1→V2 export/reimport), and `ModelContainerFactory.swift`.
- **Freeze a NEW schema version; never edit a shipped one.** SwiftData keys entities off class name and a computed version hash; a frozen snapshot must keep matching what that build wrote to disk. `SchemaDriftTests` guards this.
- Every model change bumps the schema and adds its migration stage in the same PR, tested against realistic aged fixtures (`onUpgrade`-equivalent must not throw on a tester's real data).
- A failing store-open must never destroy data or dead-end the app. `ModelContainerFactory` distinguishes "store newer than app" (never delete) from genuine corruption (backed-up, user-consented reset only). See issues #529, #708.

## Accessibility implementation requirements

- Every interactive control has a correct `accessibilityLabel`, and `accessibilityValue`/`accessibilityHint`/`accessibilityAddTraits` where they add meaning.
- Quick Actions map to the VoiceOver **actions rotor**; keep the user's configured order. Refactors preserve spoken labels, values, traits, rotor actions, and focus **byte-for-byte** unless Michael approves a semantics change.
- Post-mutation focus is moved deliberately (e.g. `AccessibilityFocusState`) to a stable anchor; never strand focus on a removed row.
- All text scales with Dynamic Type; nothing clips at the largest size. Touch targets ≥ 44pt. Color is never the only signal. Reduce Motion respected. Focus order matches visual order.
- Meaningful state changes are announced via the app's Announcer, sparingly.

See `docs/swiftui-accessibility-audit.md` and the `earshot-accessibility` agent.

## Project generation and build

- `project.yml` (repo root) is the source of truth. After changing it, run `xcodegen generate` **from the repo root** and commit the regenerated `Earshot.xcodeproj` (the project is committed; CI builds it directly, no xcodegen in CI).
- Local build/test example (StoreKit suites are quarantined under this Xcode — #679):
  ```bash
  xcodebuild test -project Earshot.xcodeproj -scheme Earshot -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skip-testing:EarshotTests/PaywallViewModelTests \
    -skip-testing:EarshotTests/ProductCatalogServiceTests \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  ```
- **Signing:** command-line overrides only — `-allowProvisioningUpdates`, `DEVELOPMENT_TEAM=72PH974742`, automatic signing. Never edit project signing settings, entitlements, or capabilities without sign-off.

## Deploy to TestFlight

Run the deploy script from the feature branch after the code is committed:

```bash
bash tool/swiftui-testflight.sh --notes "Fix: <brief description of what was fixed>"
```

The script bumps `CURRENT_PROJECT_VERSION` in `project.yml`, regenerates the project via xcodegen, archives with `xcodebuild`, and uploads to the Internal Testing Group. **Never pre-bump the build number manually.** Builds go out from the feature branch, not from main; main gets the change after Michael verifies on device and the PR is merged.

After upload, tell Michael: the build number, the issue being tested, exact step-by-step device instructions, what correct behavior looks like, and what the broken behavior looked like before.

## Fix / feature workflow

1. Read the full issue first: `gh issue view <number>`.
2. Branch off main into a **linked worktree** (never develop directly in `~/code/earshot`, which may hold Michael's uncommitted docs): `git checkout -b fix/issue-<n>-<slug>`.
3. Outline the change and files affected. Wait for confirmation before writing code.
4. Fix only what the issue describes. No scope creep. No new dependencies.
5. Run `earshot-accessibility` on any UI change before considering it done.
6. Commit (Conventional Commits), push, open a PR into `main`, assign `@payown`. Keep non-generated changes reviewable (~1,500 lines).
7. Deploy to TestFlight from the branch; give Michael device test steps.
8. **Stop and wait.** Do not merge or close the issue until Michael verifies on device.

If a fix did not work, stay on the branch and keep investigating.

## Working style preferences

- **Plan-first, code-second.** Outline what's changing and why; for multi-step work, propose steps and get confirmation.
- **One issue per branch, one branch per PR.** Never bundle unrelated changes.
- **Conversational, direct tone.** No hedging.
- **Short responses on simple questions.** Detail only where needed.

## What to NOT do

- Don't work directly on main, or develop in `~/code/earshot` directly.
- Don't start coding before outlining the change and getting confirmation.
- Don't bundle multiple issues into one branch or PR.
- Don't merge a PR until Michael confirms on device; don't close an issue without that.
- Don't touch `SettingsReset`, accessibility semantics, signing, entitlements, capabilities, or purchase UI without explicit sign-off.
- Don't add Swift package dependencies without confirmation.
- Don't edit a shipped/frozen SwiftData schema version.

## Repository structure

```
earshot/
├── Earshot/                 # SwiftUI app source
│   ├── App/                 # App entry, RootView
│   ├── Core/                # Shared UI, networking, theme
│   ├── Data/                # Models (@Model) + Persistence (schema, migration)
│   └── Features/            # Feature modules (Folders, Player, Inbox, ...)
│       └── <feature>/{Data,Domain,Presentation}
├── EarshotTests/            # XCTest suite
├── Earshot.xcodeproj/       # Generated from project.yml, committed
├── project.yml              # XcodeGen source of truth
├── scripts/                 # Screenshot capture, etc.
├── tool/
│   └── swiftui-testflight.sh # Deploy to TestFlight
├── docs/                    # Product + design docs, decision logs
├── archive/flutter/         # Retired Flutter implementation (reference only)
├── SWIFTUI_PLAN.md          # SwiftUI plan + decision log
├── AGENTS.md                # Agent guidance
├── LICENSE / README.md / CLAUDE.md
```

## Related documents

- SwiftUI plan + decisions: `SWIFTUI_PLAN.md`
- Agent guidance: `AGENTS.md`
- Accessibility rules: `.claude/rules/accessibility.md`
- Migration rules: `.claude/rules/database-migrations.md`
- Git/PR workflow: `.claude/rules/git-workflow.md`
- Security/perf reviews: `docs/code-review-2026-07-18.md`, `docs/perf-baseline.md`
- Retired Flutter app: `archive/flutter/` (restore point: `git checkout flutter-final`)
