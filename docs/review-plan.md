# Swift 6 Security Review Plan

Date: 2026-07-18  
Branch: `agent/swift-6-security-review`  
Base: `origin/swift` at `4109d2b`  
Scope: native SwiftUI app in `EarshotSwift`

## Gates and constraints

- [x] Work in a clean linked worktree; the primary `swift` worktree's App Store documentation edits remain untouched.
- [x] Require Xcode 26.6, Apple Swift 6.3.3, and XcodeGen 2.45.4.
- [ ] Reauthenticate GitHub CLI before publishing. Blocker: the saved `payown` token is invalid.
- [ ] Stop for approval if a critical fix spans more than two files, a dependency requires a major-version bump, an existing test appears wrong, or projected non-generated changes exceed 1,500 lines.
- [ ] Do not edit `SettingsReset`, retained Flutter-migration constants or cleanup behavior covered by issue #395, issue #395, accessibility modifiers or labels, signing, identifiers, entitlements, provisioning, or capabilities.
- [ ] Do not enable default MainActor isolation.

## Review order and status

| Phase | Status | Notes |
|---|---|---|
| Unchanged baseline build and complete unskipped tests | In progress | Exact summaries pending. |
| Inventory all production Swift files | Pending | Expected count will be recorded after source-membership validation. |
| Security and App Store readiness | Pending | Includes full Git history secret scan, StoreKit, untrusted inputs, transport security, file protection/backup, privacy manifest, and deprecated APIs. |
| Stability | Pending | Force operations, persistence, lifetimes, races, actors, background work, feed refresh, republish, and queue grouping. |
| Performance | Pending | Launch, main-thread work, coalescing, SwiftUI recomputation, caches, and large libraries. |
| Accessibility preservation | Pending | Changed paths must retain VoiceOver names, traits, focus, rotor actions, and gated UI. |
| Swift 6 language-mode conversion | Pending | Narrow isolation only; complete strict concurrency. |
| Critical/high fixes and regression tests | Pending | Each qualifying fix isolated and verified. |
| Final report and verification | Pending | Clean Debug/Release builds and complete unskipped suite. |
| Publish ready-for-review PR against `swift` | Blocked | GitHub CLI reauthentication required. |

## Planned configuration changes

- Set the iOS deployment target from 17.0 to 18.0.
- Set `SWIFT_VERSION` from 5.0 to 6.0.
- Set `SWIFT_STRICT_CONCURRENCY` from `minimal` to `complete`.
- Regenerate `Earshot.xcodeproj` with XcodeGen 2.45.4.
- Remove the pre-iOS-18 fallback in `SearchFieldFocus` while preserving VoiceOver autofocus suppression exactly.
- Do not change Swift dependencies; the project currently has no `Package.swift` or third-party Swift package dependency.

## Verification commands

Run from `EarshotSwift` against a compatible iOS simulator selected during baseline:

```sh
xcodegen generate
xcodebuild clean build -project Earshot.xcodeproj -scheme Earshot -configuration Debug -destination '<selected simulator>' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild clean build -project Earshot.xcodeproj -scheme Earshot -configuration Release -destination '<selected simulator>' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild test -project Earshot.xcodeproj -scheme Earshot -configuration Debug -destination '<selected simulator>' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

No StoreKit skip environment variable is permitted for baseline or final verification. Targeted test commands will be added for each critical/high fix.

## Milestone results

### Milestone 1: unchanged baseline

- Build: pending.
- Complete unskipped tests: pending.
- Compiler warnings: pending.
- Toolchain/provisioning diagnostics: pending.

### Milestone 2: upgraded final state

- Debug build: pending.
- Release build: pending.
- Complete unskipped tests: pending.
- Compiler, strict-concurrency, and deprecation warnings: pending.
- Unrelated toolchain/provisioning diagnostics: pending.

## Findings and line budget

| Checkpoint | Critical | High | Medium | Low | Non-generated lines changed |
|---|---:|---:|---:|---:|---:|
| Start | 0 | 0 | 0 | 0 | 0 |
| After audit | Pending | Pending | Pending | Pending | Pending |
| After concurrency conversion | Pending | Pending | Pending | Pending | Pending |
| Before publishing | Pending | Pending | Pending | Pending | Pending |

Generated Xcode project changes are excluded from the 1,500-line gate. Documentation, configuration, production code, and tests are included.

## Exclusions and unresolved human decisions

- Purchase UI changes require human sign-off and are excluded from implementation.
- Forbidden settings, migration, accessibility-label/modifier, and capability areas above are report-only even if a concern is found.
- Medium and low findings receive proposed GitHub issue titles in the final report; issues will not be created.
- Critical/high candidates are implemented only when they satisfy the explicit file, dependency, test-validity, and line-budget gates.

## Blockers

- GitHub CLI authentication for `payown` is invalid. Local review and verification can proceed; pushing and PR creation cannot.
