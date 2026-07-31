# Git and PR workflow

## Branches

- `main` is the trunk and holds the shipping **SwiftUI** app. It must always be
  stable and deployable. Do not commit to `main` directly; every change is a
  branch + PR.
- Work on feature branches in **linked worktrees** — never develop directly in
  `~/code/earshot`, which may hold Michael's uncommitted docs.
- Feature branches: `feature/<short-description>` (e.g. `feature/smart-folders`)
- Bug fixes: `fix/issue-<n>-<short-description>`
- Phase work: `phase/<n>-<short-name>`

## Commits

- Conventional Commits:
  - `feat: add nested folder picker`
  - `fix: prevent crash when queue is empty`
  - `docs: rework folders PRD for SwiftUI`
  - `chore: bump build number to 158 for TestFlight`
  - `test: add migration test for schema V6`
  - `refactor: extract download service`
- Small, focused commits. One logical change each. The body explains **why**.

## Pull requests

Before opening a PR:

1. The Swift tests pass locally (see `.claude/rules/database-migrations.md` for
   the exact `xcodebuild test` invocation and the StoreKit-suite skips):
   ```bash
   xcodebuild test -project Earshot.xcodeproj -scheme Earshot -configuration Debug \
     -destination 'platform=iOS Simulator,name=iPhone 17' \
     -skip-testing:EarshotTests/PaywallViewModelTests \
     -skip-testing:EarshotTests/ProductCatalogServiceTests \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
   ```
2. Any schema bump has its matching migration test (required gate — see
   `database-migrations.md`).
3. New behavior has tests.
4. `earshot-accessibility` run on any UI change; VoiceOver-tested on device when
   UI changed.
5. `CHANGELOG.md` updated for user-visible changes.
6. If `project.yml` changed, `Earshot.xcodeproj` regenerated (`xcodegen
   generate` from the repo root) and committed.

Target PRs to `main` and assign `@payown`. Keep non-generated changes
reviewable (~1,500 lines).

PR description template (`.github/PULL_REQUEST_TEMPLATE.md`):

```markdown
## What
Short summary of the change.

## Why
The user need or bug this addresses.

## Accessibility checklist
- [ ] Tested with VoiceOver on device
- [ ] All interactive elements have correct label / value / traits
- [ ] Color is not the only signal
- [ ] Touch targets ≥ 44pt
- [ ] Tested at largest Dynamic Type size

## Testing notes
How a reviewer can verify this.
```

## Swift CI

`.github/workflows/swift-ci.yml` runs the full `EarshotTests` suite
(`xcodebuild test`) on every push and PR into `main` (no path filters, so it
always runs and is safe to mark "Required" in branch protection). It runs on a
self-hosted Apple Silicon Mac with a pinned Xcode and a dedicated CI simulator.
A failing schema migration must be caught here, not by a TestFlight tester (see
`database-migrations.md`, issue #656).

## Code review

- Accessibility regressions block merge, no exceptions.
- One maintainer approval required.
- Author resolves conversations, not the reviewer.

## TestFlight

- **Device verification is pre-merge.** The normal way to get Michael a build to
  test is a **test build from the branch**, before merging to `main`:
  `tool/swiftui-testflight.sh --test [--both]`. For a batch of related work, cut
  it from an **integration branch** (e.g. `test/<feature>`) that merges the
  feature branches together, so he tests the whole thing at once. `--test`
  permits a non-`main` branch and commits the build-number bump there; that bump
  rides along when the work later merges to `main`. Merge to `main` only after
  Michael verifies on device.
- A user-facing build also gets a Kashe chapter (`earshot-kashe`) for the release
  notes.

## Releases

- iOS/iPadOS only. Production releases deploy from a clean `main`
  (`tool/swiftui-testflight.sh [--both]`).
- Tag releases on `main`: `v1.0.0`, `v1.0.1`, …, with GitHub release notes from
  `CHANGELOG.md`. The App Store build number bumps on every release.
