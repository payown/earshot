# Home Screen badge — September 23, 2026

StartTesting feature: `959cdf4d-3c49-4b45-932a-851d3df62cd4`.

The user approved the native “Badge downloaded unheard episodes” toggle after
requesting the next due task. It is in Settings → Appearance, defaults off, and
is device-local. It counts completed downloads with a local path and no played
state. A heard episode re-added to Queue is excluded even if its status changes.
Orphan download rows are ignored; duplicate composite feed/GUID keys count once.

## Responsiveness and updates

Only completed local download keys are fetched, followed by a bounded episode
lookup on a worker. No live query or library traversal runs on the main actor.
Only a scalar count crosses back. Refreshes follow download save metadata,
explicit played-state, Inbox, Queue, subscription, Cloud projection, preference,
and foreground events. Ordinary Episode-only position saves are ignored. When
off, no counting runs and the icon badge is cleared.

One process-wide writer serializes system badge updates. A revision guard drops
outdated counts; disabling during an in-flight write schedules clearing after
that write. Count errors preserve the previous badge and retry on the next event.
The badge can only update while iOS gives the process execution time; returning
to the foreground reconciles changes missed while suspended.

## Permissions and accessibility

Only explicit opt-in requests badge-only permission. Loading a saved preference
never requests authorization. Existing enabled badge permission is reused. A
prior denial or disabled system badge setting leaves the option off and presents
a native alert explaining where to enable badges. The setting does not add
custom VoiceOver labels or change existing tab badge semantics.

Existing notification opt-in now supplies alert/sound/badge options even if a
prior badge-only grant made the overall authorization status authorized. Denied
permission still returns without requesting. This is necessary to keep the new
badge option from suppressing a later explicit notification opt-in.

## Independent review

The second agent reviewed the production changes read-only. Findings corrected:
heard episodes requeued without clearing playedAt, overlapping writers across
root-view replacement, and badge-only authorization interaction with alert
opt-in. Re-review found no remaining implementation blocker. The final review approved
revision `f976221` for phone testing, with physical acceptance still pending.

## Automated evidence

- Focused badge and notification tests: 43 passed (8 badge, 35 notification).
- Initial full iOS 27 unit run: 2,399 total, 29 skipped, one failure in
  `StoreRecoveryTests.testBenignNewerStoreIsNeverDeleted`. The assertion compared
  bytes in a newly seeded future-version SQLite store. Recovery code and this
  fixture are unchanged; the independent reviewer identified a possible WAL
  checkpoint/teardown race, not a proven baseline failure.
- Initial iOS 27 UI runs stalled during native notification permission handling.
  Both iOS 27 simulators subsequently shut down unexpectedly, and the isolated
  recovery rerun failed to launch with a Mach server-died error. Verification is
  repeated on a fresh iOS 26.5 simulator: all 17 recovery tests passed, and
  the badge UI test passed default-off → on → off (18 total, zero failures).
  The test targets the trailing native switch because its accessibility frame
  includes the two-line label. No production permission changes were required.
- Signed Release 1.2.3 (267), production revision `93bb935`, built successfully
  and passed strict code-signature verification. Installed on Michael’s iPhone over Wi-Fi after independent approval.
- Final full eligible iOS 26.5 suite: 2,366 passed, 33 skipped, zero failures
  (2,399 total; both documented StoreKit suites excluded). All recovery tests
  passed. Post-test diagnostics collection was stopped after assertions finished
  so the result bundle could finalize; no test execution was interrupted.

## Phone acceptance

1. Open Settings → Appearance. Enable “Badge downloaded unheard episodes.”
   Confirm native VoiceOver label/state and grant badge permission if requested.
2. On the Home Screen, compare the badge with downloaded unheard episodes.
   A zero count should show no badge.
3. Complete or mark a downloaded episode played; remove another download;
   finish a new unheard download. Return Home and check the count each time.
4. Re-add a heard episode to Queue: it should not become unheard just by being
   queued. Mark it unheard explicitly and confirm the badge includes it.
5. Disable the option and confirm the badge clears. Reopen Earshot and confirm
   the setting remains off and no permission prompt appears.
6. If badges are disabled in iPhone Settings, try enabling the option and check
   the guidance alert. Existing new-episode/download notifications should still
   work after their own explicit opt-in.

Physical acceptance remains pending. No TestFlight distribution was requested.
