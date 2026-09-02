# Background main-actor reduction — direct-device handoff

Date: 2026-09-02  
Branch: `codex/background-mainactor-work`  
Base: `e559d13` (`origin/main`, build 251 integration record)

## Scope

This follow-up moves global/folder Inbox snapshot queries, Listening Places
payload preparation, and launch-time expiration maintenance to private SwiftData
contexts. UI state publication, focus changes, announcements, and model mutation
entry points remain main-actor isolated.

The Inbox loader intentionally returns the complete matching identity set. That
preserves full-scope search, counts, Clear Inbox, Download All, and selection
behavior. It improves main-actor availability but does not yet satisfy the
planned first-100-only paging/memory contract.

## Automated verification

- Focused concurrency and behavior suite: 36 tests, 0 failures.
- Full suite: 2,234 unit tests with 29 expected skips, 0 failures; 2 UI tests,
  0 failures. The skipped StoreKit suites are the Xcode 26.6 issue documented in
  repository guidance.
- Clean optimized Release build completed with Swift 6 complete strict
  concurrency. Signing used command-line automatic-signing overrides only.
- Tests explicitly verify the Inbox, Listening Places, and expiration store work
  did not execute on the physical main thread.

## Device delivery

Target: Michael's iPhone 17 Pro Max (`iPhone18,2`) on iOS 27.0
(`24A5430a`). The signed Release app was installed directly and launched with
bundle identifier `media.payown.earshot`; nothing was uploaded to TestFlight.

Xcode 26.6 has an iOS 26.5 SDK while the phone runs iOS 27.0. Direct build,
install, and launch work, but this toolchain/device pairing is not accepted as a
reliable Instruments baseline. No trace or numerical latency claim is recorded.

## Manual VoiceOver checks

These remain for Michael on the installed build:

1. Cold-launch Earshot and confirm the first focused element speaks immediately.
2. Open the global Inbox, flick through the first page, search, clear search, and
   use one row Action.
3. Open a folder-scoped Inbox, return from an episode or podcast destination, and
   confirm focus returns to the correct scope.
4. If Listening Places is enabled, choose **Write now** and confirm VoiceOver
   remains responsive while the file is prepared.

Stop and return to build 251 if speech repeats, focus jumps scopes, Inbox ordering
or counts differ, actions disappear, or launch visibly stalls.
