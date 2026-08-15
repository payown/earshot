# Build 203 pre-TestFlight device test

Owner: Michael Babcock
Candidate: Earshot 1.1.0 build 203
Purpose: reproduce the exact build-202 failure path before upload

Do not upload build 203 until this test passes.

## Agent-completed preflight

- [x] Build number is 203 in `project.yml` and the regenerated Xcode project.
- [x] Focused folder and Cloud tests: 132 passed, 1 opt-in skip, 0 failed.
- [x] 120-feed/54,000-episode cold projection and folder read: 0.092 seconds.
- [x] Real build-155 fixture: 53,946 episodes migrated V5 to V10 in 1.874
  seconds; first post-migration projection completed in 0.199 seconds.
- [x] Full non-StoreKit suite: 1,846 executed, 39 documented skips, 0 failed.
- [x] Signed Release archive and local App Store Connect export verified.
- [x] Export has Production CloudKit/APNs, the expected container, privacy
  manifest, beta reports, and `get-task-allow=false`.
- [ ] Exact physical upgrade reproduction below.

1. Install public App Store Earshot 1.0.0 build 155 on the iPhone.
2. Import an OPML file containing at least 60 subscriptions. A larger file is
   welcome but is not required; automated coverage already uses 120 feeds and
   54,000 episodes.
3. Open Library and confirm the imported podcasts are present.
4. Without deleting Earshot or its data, install the signed build-203 candidate
   over build 155 from the Mac.
5. Launch Earshot and complete **Upgrading your library database**.
6. Keep Earshot in the foreground until Library appears. Do not force quit it.
7. With VoiceOver, move through Library, Inbox, Queue, Folders, and the mini
   player. Confirm focus responds immediately and audio controls remain usable.
8. Open Settings, iCloud Sync. `Syncing` may appear temporarily, but the screen
   and Library must remain responsive. Wait for `Available` and a current
   `Last completed on this device` value.
9. Force quit once, reopen, and confirm the imported subscriptions remain.
10. Report pass/fail, approximate migration time, subscription count, any crash,
    any long freeze, and the final iCloud status.

Stop immediately on a crash, a migration that cannot finish, missing data,
repeated relaunch, an unbounded Syncing state, or VoiceOver becoming unresponsive.
