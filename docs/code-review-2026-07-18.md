# Earshot native Swift security and stability review

Date: 2026-07-18  
Base: `origin/swift` at `4109d2b`  
Scope: all 189 production Swift files under `EarshotSwift/Earshot`, the generated project and app configuration, plus repository history relevant to secret exposure

## Executive summary

The review found no critical issues, two high-severity concurrency defects, no medium issues, and three low-severity hardening opportunities. Both high findings are fixed in this branch with regression coverage. The app is upgraded to the Swift 6 language mode with complete strict concurrency and retains per-declaration isolation; default MainActor isolation is not enabled.

StoreKit purchase and entitlement code rejects unverified transactions and refreshes `Transaction.currentEntitlements` at launch while observing transaction updates. No StoreKit production or purchase-UI code changed. The Xcode 26.6 CLI StoreKitTest defect tracked by #679 prevents reliable CLI execution of `PaywallViewModelTests` and `ProductCatalogServiceTests`; final CLI verification explicitly excludes only those classes under the approved merge-gate exception.

No credential value or private key was found in the current native app or Git history. Historical references to Podcast Index and analytics credential variable names contained placeholders or CI secret expressions, not committed secret values.

## Findings

### High — shared feed date formatters raced during concurrent refresh

- Location after fix: `EarshotSwift/Earshot/Features/Subscriptions/Data/RSSParser.swift:99`
- Impact: `DateFormatter` and `ISO8601DateFormatter` are mutable Foundation objects. Reusing global instances from concurrent feed refreshes could produce incorrect publication dates or crash while parsing. Incorrect dates also affect inbox high-water marks and republish decisions.
- Fix: place all reusable formatter state behind `OSAllocatedUnfairLock` and perform every parse while holding that lock. The narrow `@unchecked Sendable` annotation is documented at the declaration and is justified solely by that synchronization.
- Regression: `RSSParserTests.testParseDateIsSafeAcrossConcurrentFeedRefreshes` performs 1,000 concurrent parses across supported RFC 822 and ISO-8601 variants.
- StoreKit/accessibility: unrelated; no presentation semantics changed.

### High — now-playing artwork handler inherited main-actor isolation

- Location after fix: `EarshotSwift/Earshot/Features/Player/Data/PlayerService.swift:1899`
- Impact: MediaPlayer invokes `MPMediaItemArtwork` request handlers on a private queue. Under Swift 6, the closure created by the main-actor player service inherited actor isolation and trapped when MediaPlayer requested or converted artwork off the main actor. This crashed three existing now-playing artwork tests and could crash lock-screen/Control Center artwork delivery.
- Fix: make the request handler explicitly `@Sendable` and capture the immutable decoded `UIImage` value, preventing main-actor inheritance while leaving the now-playing dictionary mutation on the main actor.
- Regression: all five existing `NowPlayingArtworkTests` pass, including off-main artwork requests, native bounds, and consecutive updates.
- Accessibility: audio controls, labels, rotor actions and focus behavior are unchanged.

### Low — recovery fallback still terminates if an in-memory store cannot be built

- Location: `EarshotSwift/Earshot/Data/Persistence/ModelContainerFactory.swift:97`; test-host analogue at line 164
- Impact: the user-facing corrupt/newer-store recovery path calls `fatalError` if its fallback container fails. That failure is unlikely, but it converts a recoverable launch problem into an unconditional termination with no user guidance.
- Concrete fix: add a minimal non-SwiftData recovery shell or propagate a typed launch error to a dedicated recovery view. The test-host force-try can independently become a throwing test bootstrap.
- Proposed issue title: **Replace fatal SwiftData recovery fallback with a non-persistent recovery shell**

### Low — media ATS exception permits cleartext streams

- Location: `EarshotSwift/Earshot/App/Info.plist:48`; policy enforcement documented in `EarshotSwift/Earshot/Core/Networking/SecureURL.swift:3`
- Impact: `NSAllowsArbitraryLoadsForMedia` intentionally preserves playback for legacy HTTP-only podcast hosts. Such streams lack transport confidentiality and integrity, so an on-path party can observe or replace audio. Non-media requests are upgraded to HTTPS and remain ATS-protected.
- Concrete fix: measure remaining HTTP-only feeds, prefer HTTPS enclosure URLs, warn before cleartext playback, and remove the exception when compatibility permits. Dynamic podcast hosts make a static domain exception impractical.
- Proposed issue title: **Add telemetry-free HTTP media detection and a path to removing the ATS media exception**

### Low — downloaded audio is included in device backups

- Location: `EarshotSwift/Earshot/Features/Downloads/Data/DownloadPaths.swift:65`
- Impact: re-downloadable podcast media is stored in `Documents/Downloads` without the backup-exclusion resource value. Large libraries can unnecessarily enlarge iCloud/device backups. Default iOS data protection still applies; this is storage hardening, not evidence of plaintext-at-rest exposure.
- Concrete fix: set `URLResourceKey.isExcludedFromBackupKey` on the downloads directory when it is created, with a regression test for the resource value. This was not changed because download cleanup behavior overlaps the explicitly protected migration/settings area and is better handled separately.
- Proposed issue title: **Exclude re-downloadable podcast audio from device backups**

## Areas reviewed

- Security/App Store readiness: current files and relevant Git history for secrets; StoreKit verification, launch entitlement refresh and transaction observation; free-tier policy inputs; XML/HTML parsing; file paths; URL schemes and query construction; ATS; file locations; privacy manifest; deprecated APIs.
- Stability: force operations and ignored failures; store recovery; notification/task lifetimes; actor crossings; background refresh, download and audio paths; feed parsing and refresh; republish/high-water behavior; flat/grouped queue reorder logic.
- Performance: launch construction; SwiftData fetch bounds; parsing and image work; feed-refresh concurrency limits; artwork memory/disk cache; large-library regression suites.
- Accessibility preservation: reviewed every changed presentation path. VoiceOver names, traits, accessibility focus, rotor actions and accessibility-gated UI are byte-for-byte unchanged. Search autofocus still suppresses programmatic focus while VoiceOver is running.

## App Store and privacy conclusions

- `PrivacyInfo.xcprivacy` declares no tracking, collected data, tracking domains or required-reason API categories. No direct use of the required-reason API families (including `UserDefaults`, system boot time, disk-space enumeration or file timestamp inspection) was found in production Swift.
- StoreKit verification consistently distinguishes `.verified` from `.unverified`. Launch synchronization uses current entitlements and the transaction observer handles later changes.
- The free-tier podcast cap is based on persisted subscription state and verified entitlement state. No wall-clock-derived unlock was found.
- XML parsing uses `XMLParser` with bounded network acquisition elsewhere; HTML/transcript display is converted to text rather than executed as web content. URL query construction uses `URLComponents`/query items in reviewed paths.
- No signing, identifier, entitlement, provisioning, capability or purchase-UI change is included.

## Swift 6 isolation decision

Default MainActor isolation would reduce annotations for SwiftUI views, but it would also silently main-isolate parsers, cache/network helpers, background feed refresh and value-only policy code. That increases launch/main-thread work and obscures the real boundaries that strict concurrency is intended to expose. Per-declaration isolation is therefore retained: UI and SwiftData main-context owners are `@MainActor`; shared mutable parsing state is synchronized; values crossing tasks are Sendable; notification payloads are reduced to Sendable identifiers before actor hops.

The only production `@unchecked Sendable` added is the RSS formatter state, whose complete access is enforced by one unfair lock. `@preconcurrency` is limited to the legacy `UNUserNotificationCenterDelegate` conformance because Apple delivers those Objective-C callbacks outside Swift's modeled isolation; each UI/router action explicitly hops to the main actor.

## Legacy removal and exclusions

- Removed the sole pre-iOS-18 fallback in `SearchFieldFocus` after raising deployment to iOS 18. The retained behavior is exactly: autofocus only when requested and `UIAccessibility.isVoiceOverRunning == false`.
- No Swift packages or third-party Swift dependencies exist; none were added or updated.
- Excluded by instruction: `SettingsReset`, Flutter-migration constants/cleanup governed by #395, issue #395, accessibility modifiers/labels, signing, identifiers, entitlements, provisioning and capabilities.
- Purchase UI remains a human-sign-off area. No unresolved StoreKit product decision is introduced by this branch.

## Finding counts

| Severity | Found | Fixed here | Remaining |
|---|---:|---:|---:|
| Critical | 0 | 0 | 0 |
| High | 2 | 2 | 0 |
| Medium | 0 | 0 | 0 |
| Low | 3 | 0 | 3 |

## Verification

Final command summaries are recorded in `docs/review-plan.md`. The eligible CLI suite contains 1,369 test cases: 1,367 runnable tests plus two environment-gated diagnostic skips. `PaywallViewModelTests` and `ProductCatalogServiceTests` are the only CLI exclusions under #679 and were not affected by the production changes.
