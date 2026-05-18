# CLAUDE.md - Earshot Project Memory

This file provides essential project context to Claude Code at the start of every session. Keep it under 200 lines so it loads efficiently.

## Project identity

**Earshot** is an accessibility-first podcast player built with Flutter, targeting iOS first then Android. It is open source (MIT), free, and a Payown Media LLC project with deep connection to BITS and the ACB community.

The full product requirements live in `docs/PRD.md`. Read it whenever you need product context. Phase plans live in `docs/phases/`.

## Owner and voice

- **Owner:** Michael Babcock, Payown Media LLC
- **Contact:** michael@payown.media
- **Brand voice:** Direct, conversational, friendly. Short paragraphs. No em dashes. No corporate words ("instrumental," "crucial," "game changer," "mastering," "fulfilling"). Contractions are fine. First person where appropriate.
- **Signs as:** Michael

## Non-negotiable rules

1. **Accessibility is the highest priority.** Every UI element needs a proper semantic label, role, and state. Every PR that touches UI must include screen reader testing notes. Code that regresses accessibility is not merged.
2. **Follow system settings.** Never override the user's theme, font size, motion, or contrast preferences. Earshot reads from the system, never imposes.
3. **Minimum data collection.** Crash reports and analytics are opt-out and anonymized. Listening history is user-controlled. No third-party trackers, no advertising IDs.
4. **Free and open.** No ads. No in-app donations. External donation link only (v1.1+). All code public on GitHub under MIT.
5. **GHCP prompts always in code blocks** when generating them.
6. **Phase progression follows `.claude/rules/phase-progression.md`.** When a phase completes, verify the Definition of Done, capture learnings, and write the next phase's detailed doc before starting work on it.

## Accessibility Agents

This project uses the [Community Access](https://community-access.org) accessibility agents installed globally at `~/.claude/agents/`. They are part of the BITS/ACB-adjacent accessibility tooling ecosystem.

Invoke them by name when relevant:
- **Mobile Accessibility** — touch targets, screen reader patterns (most relevant for Earshot)
- **Cognitive Accessibility** — reading level, error prevention, consistent navigation
- **Markdown Scanner / Fixer** — runs automatically on `.md` files
- **PR Review** — accessibility-focused PR review
- **Accessibility Lead** — orchestrates full audits across specialists

For UI work, consult the Mobile Accessibility agent. For docs, the Markdown agents run automatically.

## Tech stack

- **Framework:** Flutter (stable channel, currently 3.41.x)
- **Language:** Dart
- **State management:** Riverpod
- **Audio:** `just_audio` + `audio_service`
- **Local storage:** SQLite via `drift`
- **HTTP:** `dio`
- **Logging:** `logging` package (no `print()` statements)
- **Lints:** `very_good_analysis`
- **Testing:** Flutter test framework + `mocktail`

## Architecture conventions

- **Feature-first folder structure** under `lib/features/`
- **Three layers per feature:** `data/` (repositories, models), `domain/` (use cases, entities), `presentation/` (widgets, providers)
- **No business logic in widgets.** Widgets are purely presentational.
- **Dependencies via Riverpod providers.** No global singletons. No new instances in widgets.
- **Colors from `Theme.of(context).colorScheme`.** Never hardcoded.
- **Text styles from `Theme.of(context).textTheme`.** Never inline raw font sizes.
- **No `print()`.** Use `package:logging` with a project logger.
- **`const` constructors everywhere possible.**

## Accessibility implementation requirements

- Every interactive widget has a `Semantics` wrapper or built-in semantic properties
- Custom Quick Actions use `customSemanticsActions` to expose to VoiceOver actions rotor and TalkBack custom actions
- All text scales with system Dynamic Type (use `Theme.of(context).textTheme.*`, never hardcoded font sizes)
- All touch targets minimum 48dp (Material guidance) or 44pt (HIG)
- Color is never the only signal for state
- Reduce Motion respected (`MediaQuery.of(context).disableAnimations`)
- Focus order matches visual order

## Working style preferences

- **Plan-first, code-second.** Before writing code, outline what's being changed and why. For multi-step work, propose the steps and ask for confirmation before doing them.
- **One clear next step at a time.** Don't bundle unrelated work into one PR.
- **GHCP prompts in code blocks.**
- **Conversational direct tone.** No hedging, no "I'd be happy to help."
- **Short responses on simple questions.** Detail only where needed.

## Repository structure (target)

```
earshot/
├── .claude/                # Claude Code workspace config
│   ├── rules/              # Modular rule files
│   └── commands/           # Custom slash commands
├── docs/                   # PRD, phases, design notes
│   ├── PRD.md
│   └── phases/
├── lib/                    # Flutter app source
│   ├── core/               # Shared utilities, theme, accessibility helpers
│   ├── features/           # Feature modules (player, subscriptions, etc.)
│   ├── data/               # Cross-feature data (db, network)
│   └── main.dart
├── test/                   # Unit and widget tests
├── integration_test/       # Integration tests
├── ios/                    # iOS platform code
├── android/                # Android platform code
├── assets/
├── analysis_options.yaml
├── pubspec.yaml
├── LICENSE
├── README.md
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
└── SECURITY.md
```

## What to do at the start of a session

1. Confirm which phase of the project we're in (check `docs/phases/`).
2. Run `git status` and `git log --oneline -5` to see recent work.
3. If working on a specific feature, read the relevant phase doc first.
4. Ask Michael what we're doing this session before generating code.

## What to NOT do

- Don't make architecture changes without proposing them first.
- Don't add dependencies without confirmation.
- Don't use platform channels unless absolutely necessary; prefer Flutter-native solutions.
- Don't write tests as an afterthought; write them alongside features.
- Don't suppress lints without an explanatory comment linking to a tracking issue.

## Related documents

- Full product spec: `docs/PRD.md`
- Phase plans: `docs/phases/`
- Phase progression rules: `.claude/rules/phase-progression.md`
- Accessibility rules: `.claude/rules/accessibility.md`
- Flutter style rules: `.claude/rules/flutter-style.md`
- Git workflow: `.claude/rules/git-workflow.md`
- Architecture decisions: `docs/adr/` (created as decisions are made)
