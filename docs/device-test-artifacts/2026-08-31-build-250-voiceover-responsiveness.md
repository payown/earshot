# Build 250 VoiceOver responsiveness verification

Date: 2026-08-31 (US/Pacific)

## Build under test

- Branch: `codex/voiceover-responsiveness-build-250`
- Source commit: `f53d9b2` (`Keep inbox query controls mounted`)
- Version: Earshot 1.2.0 (250)
- Toolchain: Xcode 26.6 (17F113), Apple Swift 6.3.3, XcodeGen 2.46.0
- Configuration: optimized Release, arm64, Swift 6, complete strict concurrency
- IPA: `/tmp/EarshotExport/Earshot.ipa`
- SHA-256: `7ea46f253c49f53993282bb7e905ef8dfb730ea9b4a5c4af33cb8f186dc529d0`

## Automated evidence

| Gate | Result |
| --- | --- |
| Full eligible unit suite | 2,243 executed; 30 opt-in/environment skips; 0 failures |
| UI suite | 2 executed; 0 failures |
| 45,436-episode diagnostic | Passed in 379.489 seconds; first page remained 100 models |
| 242,000-episode search diagnostic | Inconclusive: CoreSimulatorService version changed from 1171.2 to 1171.6 after 1,836.688 seconds and invalidated XCTest; no product assertion failed |
| Signed optimized archive | Passed with Apple Development signing |
| IPA export and inspection | Passed; 1.2.0 (250), arm64, minimum iOS 18.0 |
| Independent VoiceOver code-contract audit | All five identified blockers resolved; no remaining code-level install blocker |

The full suite excluded only `PaywallViewModelTests` and
`ProductCatalogServiceTests`, as required by the repository's Xcode 26.6
StoreKit finding.

The full-size Search diagnostic was run with
`TEST_RUNNER_RUN_LOCAL_SEARCH_SCALE_DIAG=1`. It remained CPU-active with bounded
process memory during fixture creation, but the simulator service was replaced
while the test process was running. Because the test never reached its
assertions, this is recorded as infrastructure-inconclusive rather than a pass
or a product failure.

## Physical-device trace gate

Target device: Michael's iPhone, CoreDevice
`BC646DE1-620A-5E51-ACDC-9D857C2CE007`, UDID
`00008150-000935441407801C`, iOS 27.0 (24A5430a), wireless
`localNetwork` transport.

The required before/after VoiceOver interaction trace was not captured. Xcode
26.6 does not support iOS 27 device tracing. Xcode 27 beta 5 later listed the
phone in `xctrace`, but the wireless CoreDevice control channel reset before a
reproducible interaction capture could be established. No wall-time,
main-thread-longest-interval, peak-memory, or right-flick latency values are
reported because fabricating or substituting idle measurements would not satisfy
the plan.

| Required physical metric | Baseline | Post-change | Status |
| --- | ---: | ---: | --- |
| Interaction wall time | — | — | Not captured |
| Longest main-thread interval | — | — | Not captured |
| Peak memory | — | — | Not captured |
| Immediate right-flick speech | — | — | Not verified |

The replacement build was therefore not installed. This preserves the existing
on-device app and data while honoring the explicit 95% confidence gate. The IPA
is ready for installation after the same-device VoiceOver trace is captured and
reviewed and the 242,000-row diagnostic is rerun under a stable Xcode 26.6
CoreSimulator service.
