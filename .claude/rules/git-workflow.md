# Git and PR workflow

## Branches

- `main` is the protected branch. Direct commits to `main` are not allowed (CI enforces).
- Feature branches: `feature/<short-description>` (e.g., `feature/quick-actions`)
- Bug fixes: `fix/<short-description>` (e.g., `fix/queue-reorder-crash`)
- Phase work: `phase/<n>-<short-name>` (e.g., `phase/3-accessibility-layer`)

## Commits

- Use Conventional Commits format:
  - `feat: add Quick Actions configurator`
  - `fix: prevent crash when queue is empty`
  - `docs: update PRD section on transcripts`
  - `chore: bump just_audio to 0.9.40`
  - `test: add widget tests for sleep timer`
  - `refactor: extract download service from subscriptions feature`
- Keep commits small and focused. One logical change per commit.
- Message body explains why, not what (the diff shows what).

## Pull requests

Before opening a PR:

1. All tests pass locally: `flutter test`
2. Lints pass: `flutter analyze`
3. Format clean: `dart format --set-exit-if-changed lib/ test/`
4. New features have tests
5. Accessibility tested with VoiceOver or TalkBack if UI changes are involved
6. CHANGELOG.md updated for user-visible changes

PR description template (also in `.github/PULL_REQUEST_TEMPLATE.md`):

```markdown
## What
Short summary of the change.

## Why
The user need or bug this addresses.

## Accessibility checklist
- [ ] Tested with VoiceOver / TalkBack
- [ ] All interactive elements have semantic labels
- [ ] Color is not the only signal
- [ ] Touch targets meet minimum size
- [ ] Tested at largest Dynamic Type size

## Screenshots / recordings
(if UI change)

## Testing notes
How a reviewer can verify this.
```

## Code review

- Accessibility regressions block merge, no exceptions.
- One approval required from a maintainer.
- Author resolves conversations, not the reviewer.

## Releases

- Tag releases on `main`: `v1.0.0`, `v1.0.1`, etc.
- Each tag has a GitHub release with notes from CHANGELOG.md.
- App Store and Play Store build numbers bump on every release.
