# Swift 6 Security Review Plan

Date: 2026-07-18  
Branch: `agent/swift-6-security-review`  
Base: `origin/swift` at `4109d2b`  
Scope: native SwiftUI app in `EarshotSwift`

## Gates and constraints

- [x] Work in a clean linked worktree; the primary `swift` worktree's App Store documentation edits remain untouched.
- [x] Require Xcode 26.6, Apple Swift 6.3.3, and XcodeGen 2.45.4.
- [x] GitHub CLI is authenticated as `payown` with repository access.
- [ ] Stop for approval if a critical fix spans more than two files, a dependency requires a major-version bump, an existing test appears wrong, or projected non-generated changes exceed 1,500 lines.
- [ ] Do not edit `SettingsReset`, retained Flutter-migration constants or cleanup behavior covered by issue #395, issue #395, accessibility modifiers or labels, signing, identifiers, entitlements, provisioning, or capabilities.
- [ ] Do not enable default MainActor isolation.

## Review order and status

| Phase | Status | Notes |
|---|---|---|
| Unchanged baseline build and complete unskipped tests | Complete with approved exception | The Xcode 26.6 CLI StoreKitTest bug is tracked in #679. Per the merge gate, CLI verification excludes only `PaywallViewModelTests` and `ProductCatalogServiceTests`; the user will run either class in Xcode if a relevant change requires it. |
| Inventory all production Swift files | Complete | The production target contains exactly 189 Swift files; the test target contains 105 Swift files. |
| Security and App Store readiness | Complete | History/current secret scan found no committed values; StoreKit verification/refresh, inputs, ATS, storage and privacy manifest reviewed. |
| Stability | Complete | Two high concurrency defects found and fixed; persistence, background work, feeds, downloads, playback and queue paths reviewed. |
| Performance | Complete | Launch, bounded fetches, parsing, refresh coalescing, artwork cache and large-library tests reviewed. |
| Accessibility preservation | Complete | No accessibility modifier/label changed; names, traits, focus, rotor actions and VoiceOver autofocus suppression retained. |
| Swift 6 language-mode conversion | Complete | Swift 6.0 mode with complete strict concurrency and narrow per-declaration isolation. |
| Critical/high fixes and regression tests | Complete | RSS formatter synchronization and MediaPlayer artwork handler isolation pass targeted tests. |
| Final report and verification | Complete | Report written; clean Debug/Release builds and eligible CLI suite pass. |
| Publish ready-for-review PR against `swift` | Pending | GitHub CLI authentication confirmed. |

## Planned configuration changes

- Set the iOS deployment target from 17.0 to 18.0.
- Set `SWIFT_VERSION` from 5.0 to 6.0.
- Set `SWIFT_STRICT_CONCURRENCY` from `minimal` to `complete`.
- Regenerate `Earshot.xcodeproj` with XcodeGen 2.45.4.
- Remove the pre-iOS-18 fallback in `SearchFieldFocus` while preserving VoiceOver autofocus suppression exactly.
- Do not change Swift dependencies; the project currently has no `Package.swift` or third-party Swift package dependency.

## Verification commands

Run from `EarshotSwift` against the iOS 26.5 iPhone 17 Pro simulator (`58857CDF-1560-410D-8F46-7381F7ADF48A`):

```sh
xcodegen generate
xcodebuild clean build -project Earshot.xcodeproj -scheme Earshot -configuration Debug -destination '<selected simulator>' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild clean build -project Earshot.xcodeproj -scheme Earshot -configuration Release -destination '<selected simulator>' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild test -project Earshot.xcodeproj -scheme Earshot -configuration Debug -destination '<selected simulator>' -skip-testing:EarshotTests/PaywallViewModelTests -skip-testing:EarshotTests/ProductCatalogServiceTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

No broad StoreKit skip environment variable is permitted for final verification. Only the two classes affected by Xcode 26.6 CLI bug #679 may be excluded explicitly. If a change affects either class or its production paths, verification pauses for the user to run the relevant class in Xcode. Targeted test commands will be added for each critical/high fix.

## Milestone results

### Milestone 1: unchanged baseline

- Build: succeeded on the iOS 26.5 iPhone 17 Pro simulator (`58857CDF-1560-410D-8F46-7381F7ADF48A`): `** BUILD SUCCEEDED **`.
- Complete unskipped tests: blocked by StoreKit test-service failure. Both iOS 26.5 and iOS 26.3 runtime runs executed 1,380 tests, with 2 environment-gated diagnostic tests skipped and 13 assertion failures (7 unexpected) caused by `SKTestSession` failing with `SKInternalErrorDomain Code=3` and returning no configured products. The exact iOS 26.3 summary was: `Executed 1380 tests, with 2 tests skipped and 13 failures (7 unexpected) in 17.256 (17.979) seconds` and `** TEST FAILED **`.
- Compiler warnings: the unchanged Swift 5 build is not warning-clean. It emits forthcoming Swift 6 isolation warnings, including sending non-`Sendable` SwiftData `Episode` values into main-actor-isolated download implementations. These are upgrade work, but the preparation gate prevents starting that conversion until the unmodified StoreKit suite runs.
- Toolchain/provisioning diagnostics: App Intents metadata extraction reports no `AppIntents.framework` dependency and skips extraction; code signing was intentionally disabled for simulator verification. Test logs also include expected simulator audio/network diagnostics. None caused the build failure.
- Result bundles: `/tmp/EarshotSwift6Baseline.xcresult` (iOS 26.5) and `/tmp/EarshotSwift6Baseline263.xcresult` (iOS 26.3).

### Milestone 2: upgraded final state

- Debug build: clean build succeeded with exit code 0 and no compiler output.
- Release build: clean build succeeded with exit code 0 and no compiler output.
- Complete eligible CLI tests: passed; 1,369 executed, 1,367 passed, 2 environment-gated diagnostic skips, 0 failures. Only the two #679 StoreKit classes were explicitly excluded.
- Compiler, strict-concurrency, and deprecation warnings: zero from app and test source.
- Targeted high-fix tests: all 5 `NowPlayingArtworkTests` pass; `RSSParserTests.testParseDateIsSafeAcrossConcurrentFeedRefreshes` passes as part of the complete suite.
- Unrelated toolchain/provisioning diagnostics: App Intents metadata extraction may report that no AppIntents dependency exists; signing was intentionally disabled for simulator builds. Xcode's test observer timing lines are informational.

## Findings and line budget

| Checkpoint | Critical | High | Medium | Low | Non-generated lines changed |
|---|---:|---:|---:|---:|---:|
| Start | 0 | 0 | 0 | 0 | 0 |
| After audit | 0 | 2 | 0 | 3 | 313 |
| After concurrency conversion | 0 | 2 | 0 | 3 | 313 |
| Before publishing | 0 | 2 | 0 | 3 | 421 |

Generated Xcode project changes are excluded from the 1,500-line gate. Documentation, configuration, production code, and tests are included.

## Exclusions and unresolved human decisions

- Purchase UI changes require human sign-off and are excluded from implementation.
- Forbidden settings, migration, accessibility-label/modifier, and capability areas above are report-only even if a concern is found.
- Medium and low findings receive proposed GitHub issue titles in the final report; issues will not be created.
- Critical/high candidates are implemented only when they satisfy the explicit file, dependency, test-validity, and line-budget gates.

The final figure includes the 108-line review report; generated `project.pbxproj` changes remain excluded.

## Blockers

- None. The Xcode 26.6 CLI StoreKitTest failure is diagnosed as upstream bug #679 and has an explicit merge-gate exception limited to `PaywallViewModelTests` and `ProductCatalogServiceTests`.
