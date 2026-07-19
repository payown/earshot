# Earshot agent guidance

## Toolchain and project generation

- Required toolchain: Xcode 26.6, Apple Swift 6.3.3, and XcodeGen 2.45.4.
- The app uses Swift 6 language mode with complete strict concurrency and targets iOS 18.0.
- `EarshotSwift/project.yml` is the project source of truth. After changing it, run `xcodegen` from `EarshotSwift/` and commit the regenerated project.
- There are no third-party Swift dependencies.

## Tests and StoreKit

- On this host under Xcode 26.6, `PaywallViewModelTests` and `ProductCatalogServiceTests` fail with `SKInternalErrorDomain Code=3` through both CLI and Xcode IDE runners. This is the corrected 2026-07-18 finding tracked by #679, not a product regression; CI skips both suites.
- Exclude them from local runs with `-skip-testing:EarshotTests/PaywallViewModelTests -skip-testing:EarshotTests/ProductCatalogServiceTests`. Verify StoreKit purchases with Sandbox on a physical device.

## Worktrees, reviews, and protected scope

- Target PRs to `swift`. Work only on feature branches in linked worktrees; never develop directly in `~/code/earshot`, which may contain Michael's uncommitted documentation.
- Assign PRs to `@payown`. Keep commits small and screen-reader-reviewable. Keep non-generated PR changes within 1,500 lines.
- Do not touch issue #395 areas, `SettingsReset`, accessibility semantics, signing, entitlements, capabilities, or purchase UI without explicit sign-off.
- For device signing, use command-line overrides only: `-allowProvisioningUpdates`, `DEVELOPMENT_TEAM=72PH974742`, and automatic signing. Never edit project signing settings.

## Accessibility and device profiling

- Michael is blind and uses VoiceOver. Treat every UI as VoiceOver-first and VoiceOver responsiveness as a first-class performance metric; Michael's on-device reports are measurements.
- Refactors must preserve spoken labels, values, traits, rotor actions, and focus behavior byte-for-byte unless Michael explicitly approves a semantics change.
- Michael's iPhone may run an iOS beta newer than the installed Xcode device support. In that state, Instruments/`xctrace` drops the phone even when `devicectl` build, install, and launch work. Check the phone OS against Apple's Xcode compatibility matrix before tracing; install a matching Xcode beta when required.

## Durable references

- Security and stability review: `docs/code-review-2026-07-18.md`
- Performance baseline and VoiceOver investigation: `docs/perf-baseline.md`
- Open review follow-ups: #708 (SwiftData recovery), #709 (ATS media exception), and #710 (download backup exclusion)
