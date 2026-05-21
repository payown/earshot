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

The `accessibility-agents@community-access` plugin (v3.2.0) is installed. Agent files are symlinked from the plugin cache into `~/.claude/agents/` — if they stop resolving after a plugin update, re-run:

```bash
for f in ~/.claude/plugins/cache/community-access/accessibility-agents/3.2.0/agents/*.md; do
  ln -sf "$f" ~/.claude/agents/$(basename "$f")
done
```

**Invoke via the Agent tool** with `subagent_type: "accessibility-agents:<name>"`:

| When | Agent |
|------|-------|
| Any Flutter UI change | `accessibility-agents:mobile-accessibility` |
| Full audit / unknown scope | `accessibility-agents:accessibility-lead` (web-focused, use mobile for Flutter) |
| Docs / markdown | `accessibility-agents:markdown-a11y-assistant` |
| PR review | `accessibility-agents:pr-review` |

**Rule:** Use `accessibility-agents:mobile-accessibility` on every PR that touches Flutter UI before merging. Do not skip this even for "small" changes.

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
5. For any UI PR: run `accessibility-agents:mobile-accessibility` before merging.
6. To deploy to TestFlight: run `bash tool/testflight.sh --notes "..."` from repo root. The script bumps the build number itself — never pre-bump manually.

## Flutter accessibility patterns (hard-won)

These were discovered through VoiceOver testing — add to `.claude/rules/accessibility.md` for detail.

**Do:**
- Use `barrierLabel: 'Dismiss ...'` on every `showModalBottomSheet` call
- Use `Semantics(header: true, label: title, child: ExcludeSemantics(child: Text(title)))` for sheet headings — explicit `label:` AND exclude the child Text to avoid a duplicate node
- Use `Semantics(button: true, label: '...', child: ExcludeSemantics(child: FilledButton(...)))` — exclude the WHOLE button widget, not just its text child
- Trust built-in widget semantics: `CheckboxListTile`, `Switch`, `Slider`, `IconButton` all handle their own roles correctly
- Put decorative icons in `ExcludeSemantics` when they sit alongside labeled text

**Don't:**
- `ExcludeSemantics(child: CheckboxListTile(...))` — strips the gesture recognizer, iOS marks the node "dimmed" and unable to interact
- `Semantics(checked: ..., onTap: ..., child: ExcludeSemantics(child: CheckboxListTile(...)))` — `checked:` without a proper widget type maps to "switch button" not "checkbox" on iOS
- `Focus(autofocus: true)` on a container Column/widget — VoiceOver treats it as a group and announces a merged summary of all children on entry; use `barrierLabel` instead to route focus
- `Semantics(button: true, label: '...', child: SomeInteractiveWidget(...))` without `ExcludeSemantics` on the child — creates two button nodes (the outer Semantics node AND the widget's own)

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
