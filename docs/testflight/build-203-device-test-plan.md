# Build 205 pre-TestFlight device test

Owner: Michael Babcock
Candidate: Earshot 1.1.0 build 205
Purpose: reproduce the exact build-202 failure path before upload

Status: passed on 2026-08-15

## Agent-completed preflight

- [x] Build number is 205 in `project.yml` and the regenerated Xcode project.
- [x] Final focused Cloud projection run: 35 passed, 0 failed.
- [x] Production-shaped 99-subscription, 948-tombstone, 53,944-episode
  projection: first reconciliation 0.307 seconds; repeated reconciliation
  0.305 seconds. The gate is 5 seconds.
- [x] The build-155 fixture migration and first projection remain covered; the
  exact iOS 27 production store was profiled on the physical phone because the
  iOS 26.5 simulator runtime cannot open its newer Core Data store format.
- [x] Full non-StoreKit suite: 1,835 executed, 28 documented skips, 0 failed.
- [x] Signed Release archive and final App Store distribution export verified.
- [x] Export has Production CloudKit/APNs, the expected container, privacy
  manifest, beta reports, and `get-task-allow=false`.
- [x] App Store Connect processed build 205 as VALID, assigned it to both
  tester groups, retained Chapter 64 as What to Test, and approved external
  beta review.
- [x] Exact physical upgrade reproduction below. Cold launches and background
  returns completed in approximately 1–1.5 seconds, VoiceOver remained
  responsive, and the imported library remained intact and usable.

1. Install public App Store Earshot 1.0.0 build 155 on the iPhone.
2. Import an OPML file containing at least 60 subscriptions. A larger file is
   welcome but is not required; automated coverage already uses 120 feeds and
   54,000 episodes.
3. Open Library and confirm the imported podcasts are present.
4. Without deleting Earshot or its data, install the signed build-205 candidate
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
