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

1. **Never work directly on main.** Every fix, feature, or change gets its own branch. Main must always be stable and deployable.
2. **Accessibility is the highest priority.** Every UI element needs a proper semantic label, role, and state. Every PR that touches UI must include screen reader testing notes. Code that regresses accessibility is not merged.
3. **Follow system settings.** Never override the user's theme, font size, motion, or contrast preferences. Earshot reads from the system, never imposes.
4. **Minimum data collection.** Crash reports and analytics are opt-out and anonymized. Listening history is user-controlled. No third-party trackers, no advertising IDs.
5. **Free and open.** No ads. No in-app donations. External donation link only (v1.1+). All code public on GitHub under MIT.
6. **GHCP prompts always in code blocks** when generating them.
7. **Phase progression follows `.claude/rules/phase-progression.md`.** When a phase completes, verify the Definition of Done, capture learnings, and write the next phase's detailed doc before starting work on it.

## Accessibility agents

Agent files are installed at `~/.claude/agents/` from the `accessibility-agents` plugin (v3.2.0).

If agents stop resolving after a Claude Code update, reinstall from the local repo:

```bash
cd ~/.claude/.a11y-agent-team-repo && bash install.sh
```

**Invoke via the Agent tool** using just the agent name (no namespace prefix needed):

| When | Agent |
|------|-------|
| Any Flutter UI change | `mobile-accessibility` |
| Full audit / unknown scope | `accessibility-lead` |
| Docs / markdown | `markdown-a11y-assistant` |
| PR review | `pr-review` |

**Rule:** Run `mobile-accessibility` on every PR that touches Flutter UI before merging. Do not skip this even for "small" changes.

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

## Flutter accessibility patterns (hard-won)

These were discovered through VoiceOver testing. Add detail to `.claude/rules/accessibility.md`.

**Do:**
- Use `barrierLabel: 'Dismiss ...'` on every `showModalBottomSheet` call
- Use `Semantics(header: true, label: title, child: ExcludeSemantics(child: Text(title)))` for sheet headings
- Use `Semantics(button: true, label: '...', child: ExcludeSemantics(child: FilledButton(...)))` — exclude the WHOLE button widget, not just its text child
- Trust built-in widget semantics: `CheckboxListTile`, `Switch`, `Slider`, `IconButton` all handle their own roles correctly
- Put decorative icons in `ExcludeSemantics` when they sit alongside labeled text

**Don't:**
- `ExcludeSemantics(child: CheckboxListTile(...))` — strips the gesture recognizer, iOS marks the node "dimmed"
- `Semantics(checked: ..., onTap: ..., child: ExcludeSemantics(child: CheckboxListTile(...)))` — maps to "switch button" not "checkbox" on iOS
- `Focus(autofocus: true)` on a container Column — VoiceOver treats it as a group and announces a merged summary
- `Semantics(button: true, label: '...', child: SomeInteractiveWidget(...))` without `ExcludeSemantics` on the child — creates two button nodes

## Bug fix workflow

This is the primary workflow right now. There are 7 open issues on GitHub (payown/earshot, issues #15-21) to work through one at a time.

**For each issue:**

1. Ask Michael which issue number to start with.
2. Read the full issue on GitHub before touching any code: `gh issue view <number>`
3. Check out a new branch from main before writing anything:
   ```bash
   git checkout main && git pull origin main
   git checkout -b fix/issue-<number>-<short-description>
   ```
   Example: `git checkout -b fix/issue-15-now-playing-bar`
4. Outline the proposed fix and which files will change. Wait for Michael to confirm before writing code.
5. Fix only what the issue describes. No scope creep. No unrelated changes.
6. Run `mobile-accessibility` agent on any UI changes before considering the fix complete.
7. Commit the fix with a clear message:
   ```bash
   git add -A && git commit -m "fix: <description> (closes #<number>)"
   ```
8. Push the branch and open a PR to main:
   ```bash
   git push origin fix/issue-<number>-<short-description>
   gh pr create --title "fix: <description>" --body "Closes #<number>" --base main
   ```
9. Add a comment to the GitHub issue describing what was changed and where.
10. Build and deploy to TestFlight from the fix branch (see Deploy section below).
11. Tell Michael exactly what to test on device. Be specific about which screen, which action, and what correct behavior looks like.
12. **Stop and wait.** Do not merge the PR, close the issue, or move to the next issue until Michael confirms the fix is verified on device.
13. When Michael confirms it's working:
    ```bash
    gh pr merge --squash
    gh issue close <number> --comment "Verified fixed on device. Merged via PR."
    git checkout main && git pull origin main
    git branch -d fix/issue-<number>-<short-description>
    ```
14. Ask Michael which issue to work on next.

If Michael says a fix did not work, stay on the same branch and investigate further. Do not close the issue or merge the PR.

## Deploy to TestFlight

Run the deploy script from the fix branch after the code is committed and pushed:

```bash
bash tool/testflight.sh --notes "Fix: <brief description of what was fixed>"
```

The script will:
- Verify the working tree is clean and in sync with remote
- Bump the build number in `pubspec.yaml` and commit it automatically
- Build a release IPA
- Upload to the Internal Testing Group on TestFlight and notify testers

**Never pre-bump the build number manually.** The script handles it.

**The TestFlight build goes out from the fix branch, not from main.** Main only gets the fix after Michael verifies it works on device and the PR is merged.

After the upload completes, tell Michael:
- The build number that was deployed
- The issue number and title being tested
- Step-by-step instructions for what to do on device to verify the fix
- What correct behavior looks like
- What the broken behavior looked like before, so he knows what to compare against

Example format:
```
Build 42 is on TestFlight for issue #17 (Mark All as Played crash).

To test:
1. Open Earshot and go to the Inbox tab.
2. Tap the options button and choose Mark All as Played.
3. Confirm when prompted.
4. The app should stay responsive and show all episodes marked as played.

Before this fix, the app would freeze after you confirmed. Let me know if it feels stable or if you're still seeing the crash.
```

## Working style preferences

- **Plan-first, code-second.** Before writing code, outline what's being changed and why. For multi-step work, propose the steps and ask for confirmation before doing them.
- **One issue per branch, one branch per PR.** Never bundle unrelated fixes.
- **GHCP prompts in code blocks.**
- **Conversational direct tone.** No hedging, no "I'd be happy to help."
- **Short responses on simple questions.** Detail only where needed.

## What to do at the start of a session

1. Run `git status` and `git branch` to see where things stand.
2. If on main, confirm there's no work in progress before starting anything.
3. Ask Michael which issue to work on.
4. Read the issue fully before proposing anything.

## What to NOT do

- Don't work directly on main. Ever.
- Don't start writing code before outlining the fix and getting confirmation.
- Don't bundle multiple issues into one branch or PR.
- Don't merge a PR until Michael confirms the fix works on device.
- Don't close a GitHub issue without device verification from Michael.
- Don't move to the next issue until the current one is closed.
- Don't make architecture changes without proposing them first.
- Don't add dependencies without confirmation.
- Don't use platform channels unless absolutely necessary.
- Don't suppress lints without an explanatory comment linking to a tracking issue.

## Repository structure (target)

```
earshot/
├── .claude/                # Claude Code workspace config
│   └── rules/              # Modular rule files (create as needed)
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
│   └── icon/
│       └── icon.png        # Source icon — run tool/install_icons.py to generate all sizes
├── tool/
│   ├── testflight.sh       # Deploy to TestFlight (never run from main)
│   └── install_icons.py    # Resize icon.png into all required iOS and Android sizes
├── analysis_options.yaml
├── pubspec.yaml
├── LICENSE
├── README.md
└── CLAUDE.md
```

## Related documents

- Full product spec: `docs/PRD.md`
- Phase plans: `docs/phases/`
- Accessibility rules: `.claude/rules/accessibility.md` (create when needed)
- Flutter style rules: `.claude/rules/flutter-style.md` (create when needed)
- Architecture decisions: `docs/adr/` (created as decisions are made)
