# Contributing to Earshot

Thanks for considering a contribution. Earshot is a community project and pull requests, issues, and accessibility feedback are all valued.

## Code of conduct

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Short version: be kind, be patient, assume good intent.

## Accessibility comes first

Earshot exists to serve screen reader users. Accessibility is the highest priority, and PRs that regress accessibility will not be merged.

Every UI change must include:

1. **Screen reader testing notes** in the PR description (e.g., "Tested with VoiceOver on iOS 17 simulator; all Quick Actions reachable and properly labeled").
2. **Proper semantic labels** on every interactive element.
3. **Dynamic Type support** verified at the largest accessibility size.
4. **Color independence** verified (state is never communicated by color alone).
5. **Touch targets** at minimum sizes (48dp Android, 44pt iOS).

If you're not sure how to test with a screen reader, ask in an issue or Discord and we'll help.

## Development setup

See [README.md](README.md#building) for build instructions.

One-time setup: point git at the repo's tracked hooks so the pre-commit
formatter check runs (this also covers any `git worktree` checkouts of this
repo, since `core.hooksPath` is shared repo-wide config):

```bash
git config core.hooksPath tool/hooks
```

Run before pushing:

```bash
flutter analyze
dart format --set-exit-if-changed lib/ test/
flutter test
```

CI will fail if any of these fail.

## Branch and commit conventions

- Feature branches: `feature/<short-description>`
- Bug fixes: `fix/<short-description>`
- Phase work: `phase/<n>-<short-name>`
- Conventional Commits format: `feat:`, `fix:`, `docs:`, `chore:`, `test:`, `refactor:`

Example: `feat: add Quick Action configurator for episodes`

## Pull request process

1. Fork the repo and create your branch.
2. Make your change with tests.
3. Run the checks listed above.
4. Update CHANGELOG.md for user-visible changes.
5. Open a PR using the template.
6. Address review feedback.
7. A maintainer will merge once approved and CI is green.

## What kinds of contributions help

- **Bug fixes**, especially accessibility bugs
- **New tests** to improve coverage
- **Documentation improvements**
- **Performance optimizations** with benchmarks
- **Internationalization** (we plan to use Flutter's built-in ARB/l10n)
- **Bug reports** with clear reproduction steps

## What to avoid in PRs

- Large architectural changes without prior discussion (open an issue first)
- New dependencies without discussion
- Feature work outside the current phase (see `docs/phases/`)
- Code style preferences not in `.claude/rules/flutter-style.md`

## Reporting accessibility issues

Open an issue labeled `accessibility` with:

- Device and OS version
- Screen reader (VoiceOver, TalkBack, etc.) and version
- Steps to reproduce
- Expected vs actual behavior

Accessibility issues are triaged first.

## Reporting security issues

See [SECURITY.md](SECURITY.md).

## Questions

Open an issue or join the Discord (link in README once beta launches).
