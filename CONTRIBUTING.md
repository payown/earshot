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
5. **Touch targets** at minimum size (44pt).

If you're not sure how to test with a screen reader, ask in an issue or Discord and we'll help.

## Development setup

See [README.md](README.md) for build instructions. Earshot is a **SwiftUI +
SwiftData** iOS app; you need Xcode and (only if you edit `project.yml`)
XcodeGen. There are no third-party Swift dependencies.

Run before pushing:

```bash
xcodebuild test -project Earshot.xcodeproj -scheme Earshot -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skip-testing:EarshotTests/PaywallViewModelTests \
  -skip-testing:EarshotTests/ProductCatalogServiceTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

CI runs the same suite on every PR into `main`.

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
- **Internationalization** (SwiftUI String Catalogs)
- **Bug reports** with clear reproduction steps

## What to avoid in PRs

- Large architectural changes without prior discussion (open an issue first)
- New dependencies without discussion
- Feature work outside the current plan (see `SWIFTUI_PLAN.md`)
- Code style preferences not in the project conventions (`CLAUDE.md` / `AGENTS.md`)

## Reporting accessibility issues

Open an issue labeled `accessibility` with:

- Device and OS version
- VoiceOver version (iOS)
- Steps to reproduce
- Expected vs actual behavior

Accessibility issues are triaged first.

## Reporting security issues

See [SECURITY.md](SECURITY.md).

## Questions

Open an issue or join the Discord (link in README once beta launches).
