# Cold-launch tab responsiveness

StartTesting: `03be3a98-d1e8-4918-a5f9-29cbfbf7efc3`.
Baseline: main `3c7bec65`, shipped version 1.2.3 (269).
Production fix: `20f428e`.

The listener reports delays both when moving VoiceOver focus across bottom tabs
and after activating a tab on cold launch. Installed OS and library/download
counts were not provided. This investigation preserves existing accessibility
labels, values, traits, duplicate-badge suppression, and focus routing.

## Measurement design

Xcode 27.0, iPhone 17 simulator, iOS 26.5, dedicated simulator
`F30D7F8E-BEE0-456C-989B-9F17DE043BCC`. Debug configuration, same machine,
simulator, fixtures, commands, and five samples before/after. The CI simulator
is not used. Tests are sequential; no other benchmark runs concurrently.

- Download launch work: 1,500 real one-byte files, Episode records and matching
  device-local download rows in a synthetic in-memory store. Each sample uses
  a fresh ModelContext and manager. State is hydrated as in a usable app store.
  Time only the production reconciliation call, excluding seeding/cleanup.
  A 1ms main-actor heartbeat records its largest scheduling gap, including a
  short settling window. This is a startup-operation stress test, not a complete
  process launch or a disk-store-open measurement.
- Badge burst: real five-item UITabBarController; 100 Inbox/Queue update pairs
  with unchanged counts in a run-loop burst, five samples. Record the same
  main-actor heartbeat gap through immediate and delayed updates. This is a
  controlled stress workload, not an assertion that launch issues 200 updates.
- End-to-end: terminate and launch the app using the existing small screenshot
  fixture, then activate Inbox, Queue, Downloads, Settings, Library. Record
  launch-to-Library-availability and first-cycle wall time. XCTest waits and tap
  automation are included. Screenshot mode uses an in-memory library and skips
  network/Cloud/expiration work, so this does not model a large real library.

The simulator timings are not physical VoiceOver speech/focus latency. No claim
of a phone speedup can be made until the listener repeats the same interaction.
An initial download fixture failed its state-preservation assertion because
its synthetic local state had not been hydrated for refaulted models. Those
invalid download samples are discarded; the corrected fixture is used for the
comparison.

## Results

Median milliseconds, with minimum–maximum in parentheses. All five samples
are included; no outliers are removed. Raw values are in
[cold-launch-tabs/samples.json](cold-launch-tabs/samples.json).

| Measurement | Before | After |
| --- | ---: | ---: |
| Download scan, elapsed | 649.86 (645.82–661.69) | 68.83 (68.45–71.80) |
| Download scan, largest main-actor gap | 627.98 (622.86–637.12) | 2.10 (2.09–2.12) |
| Badge burst, largest main-actor gap | 23.27 (13.72–24.54) | 2.42 (2.26–8.06) |
| Small-fixture launch | 4403.96 (4387.73–4876.82) | 4506.58 (4361.78–4683.49) |
| First five-tab cycle | 15190.92 (15074.24–15245.26) | 15446.13 (15266.13–15568.38) |

The healthy-download scan's median elapsed time fell about 89%, and its largest
main-actor scheduling gap fell about 99.7%. Badge-burst gaps also improved. These
are controlled operation measurements. The small-fixture UI run did **not** show
a speedup: median launch was roughly 2.3% longer and the tab cycle roughly 1.7%
longer. Those runs include automation overhead and do not exercise the large
set of downloads. They establish that all five tabs remained operable, not a
claim of improved real-world launch time or measured VoiceOver latency.

## Implementation and regression checks

- Read device-local download rows and verify files off the main actor. Prepare
  the Downloads directory once per scan instead of once per file. Return only
  scalar repair candidates; healthy downloads do not materialize Episode models
  on the main actor.
- Apply repairs in batches of at most 50, yielding between batches. Reject
  results after cancellation, context release/replacement, or path/status changes.
  Recheck a missing file before clearing its state so a transfer that finished
  during the scan survives.
- Cache the four first-paint preferences for the root/store lifetime and seed
  the selected tab before awaiting service activation. Live appearance changes
  continue using the existing observed SettingsStore properties.
- Coalesce Inbox/Queue badge requests within a run loop, avoid unchanged badge
  assignments, and coalesce the delayed suppression pass. Existing immediate
  and delayed duplicate-badge accessibility suppression remain in place.

76 focused tests passed, including two measurement tests. Existing missing-file,
legacy-path, empty/nil-path and idempotence checks pass. New tests cover file/path
changes during scanning, cancellation, store release, multi-batch repairs, saved
preferences, store replacement, latest badge values, clearing, and suppression
of badges created after layout. The end-to-end test passed all five samples.
Full simulator suite: 2,433 executed, 2,400 passed, 33 skipped, zero failures.
The known host-problem StoreKit suites were excluded as required by AGENTS.md.
The added same-path restarted-transfer race test also passed in that full run.
Result bundle: `/tmp/earshot-cold-tabs/Logs/Test/Test-Earshot-2026.09.25_09-30-45--0700.xcresult`.

The bounded-scan test previously assigned local runtime state before saving its
synthetic Episodes. Temporary IDs caused B's persisted local row to contain A's
path, while B's live model still exposed its own path. The new stale-result
check correctly rejected that mismatch. The fixture now saves permanent IDs
before writing local state; production stale-result protection is unchanged.

## Reproduction

The exact temporary benchmark sources are retained as `.swift.txt` files in
[cold-launch-tabs](cold-launch-tabs). Copy them to `EarshotTests` and
`EarshotUITests` respectively, removing `.txt`, then run `xcodegen`. They are
intentionally excluded from normal CI; permanent regression tests remain in the
test target. Use an isolated worktree at baseline `3c7bec65` and another at the
fix, the same dedicated simulator, and run sequentially:

```sh
xcodebuild test -project Earshot.xcodeproj -scheme Earshot \
  -destination 'platform=iOS Simulator,id=F30D7F8E-BEE0-456C-989B-9F17DE043BCC' \
  -derivedDataPath /tmp/earshot-cold-tabs -collect-test-diagnostics never \
  -only-testing:EarshotTests/ColdLaunchBenchmarks \
  -only-testing:EarshotUITests/ColdLaunchTimingTests CODE_SIGNING_ALLOWED=NO
```

The retained sources are identical before and after. The original before UI
result bundle also contains the discarded invalid download-fixture run; use
only its UI samples. The corrected baseline operation run passed both tests.
After UI samples come from the initial fix run whose download-bound fixture
failed; its measurement assertions and UI checks passed. The final focused run
passed all tests and supplies the after-operation values reported here.

## Phone acceptance

1. Force-close Earshot, reopen it, and immediately flick VoiceOver focus across
   the bottom tabs. Repeat three times; compare pauses with build 269.
2. On another cold launch, double-tap each tab immediately, especially Queue and
   Downloads. Confirm tab changes and focus remain predictable.
3. Confirm Inbox and Queue counts still announce normally, without a separate
   number-only stop. Check with nonzero counts and after a count changes.
4. Confirm downloaded episodes remain available offline and the saved launch
   tab and appearance still take effect. Change appearance and check it updates
   immediately; change the launch tab and check it on the next launch.

Physical-device VoiceOver acceptance is pending. No release or merge is claimed.

