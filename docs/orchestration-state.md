# Earshot — Orchestration State

Living handoff doc for the **App Store 1.0 Launch** milestone. Future sessions
should read this from the repo instead of relying on chat summaries. Update it at
the end of each work batch (via PR, like everything else).

- **Work branch:** `swift` (NOT `main`; `swift` is not the default branch, so
  merged issues need explicit `gh issue close`).
- **Last updated:** 2026-07-11.

## CI / infrastructure

- **Runner:** self-hosted `michael-mac-selfhosted` on Michael's Mac (launchd
  service, repo-scoped, online). GitHub-hosted runners are billing-blocked —
  never target them.
- **Swift CI job name:** `Build and test (EarshotTests)` (workflow "Swift CI").
- **StoreKit tests:** 13 are quarantined on CI only via
  `TEST_RUNNER_EARSHOT_SKIP_STOREKIT_TESTS` (Xcode 26.5 xcodebuild StoreKitTest
  regression). Tracking: **#679**. Must be run manually in Xcode as part of D1
  final QA before release.
- **Branch protection:** CANNOT be enforced (private repo, free plan). Tracking:
  **#680** (assigned to Michael). Decide at launch: GitHub Pro ($4/mo) vs go
  public + secrets audit. Compensating control below.
- **Direct-push guard:** `.github/workflows/direct-push-guard.yml` — flags any
  direct push to `swift` that didn't arrive via a merged PR, opens an issue, and
  fails the run. Merged 2026-07-11 (PR #681, squash `eafb23b`). Verified it
  correctly exempts PR merges ("OK: … arrived via merged PR #681"). Interim for
  #680.

## In-flight PRs

| PR | Branch | Target | Status |
| --- | --- | --- | --- |
| **#691** | `fix/688-announcement-language` | `swift` | **Open** — #688 garbled-VoiceOver-announcement fix (A: Announcer language-pin; B: curated subscribe/feed errors). earshot-accessibility gate PASS; +12 tests, build clean. Awaiting Michael's device (VoiceOver) verification; then merge + `gh issue close 688`. |

## Milestone task status

### Done / merged this line of work
- **#681** direct-push guard — merged (`eafb23b`).
- Docs #673 / #674 / #676 / #683 / #685 — merged (do not redo).
- **C1 screenshots (#643)** — merged (PR #682, approved by Michael). Repeatable
  harness at `EarshotSwift/scripts/screenshots/`; text descriptions in
  `docs/appstore/screenshots.md`. Remaining on #643: the Earshot Plus paywall
  shot (deferred until A2 merges). iPad captures deferred with iPad support (see
  below).
- **#641 hide-played filter on Downloads** — merged (PR #684), **verified on
  device by Michael, issue closed.** Default stays All (opt-in hiding).
- **iPhone-only for 1.0 (#643 decision)** — merged (PR #687). `TARGETED_DEVICE_FAMILY = "1"`.
  iPad support + iPad screenshots deferred to 1.1 (**#686**). This removed the
  iPad screenshot requirement from the 1.0 submission.

### In progress
- **#688** — garbled VoiceOver announcement from untrusted feed data (Paul).
  PR #691, gates passed, awaiting Michael's VoiceOver device verification.
  Scoped to 1.0.

### Beta feedback (Paul) — triaged
- **#688** (garbled announcement) → **1.0**, in flight (PR #691).
- **#689** (export audio from episode rows, no play-first) → **1.1** (additive
  UX; export already works via the player).
- **#690** (flaky `testFactoryResetRemovesArtworkCacheDirectory` / reset unlinks
  artwork Cache.db while open) → low priority, fix before 1.0 QA.

### Next up
- After #688 verifies/merges, await direction. HOLD items below are not to be
  started without Michael.

### HOLD (do not start without Michael)
- **#647** — age rating questionnaire (Michael's).
- **#649** — Kashe finale chapter (ships last).
- **#650** — App Review prep (needs ASC).
- **#638 / A8** — legal copy (blocked on payown.media hosting).
- **#395** — never touch.

## Blocked on Michael (nudge if stale)

- **ASC setup:** 6 IAP products —
  `media.payown.earshot.plus.monthly/.yearly/.lifetime`
  ($2.99 / $19.99 / $49.99) and `.tip.small/.medium/.large`
  ($1.99 / $4.99 / $9.99); subscription group "Earshot Plus"; sandbox tester;
  Paid Applications agreement.
- **Small Business Program** enrollment (15% commission) right after the Paid
  Apps agreement.
- **payown.media hosting** still 403 — oldest blocker; gates the privacy policy
  URL and legal copy.
- **Heat test** on Michael's iPhone: does playback heat the phone on a
  downloaded/offline episode? (Isolates streaming-rebuffer vs outside-the-app.)

## Standing rules (reminders)

- Every change via feature branch + PR into `swift`. No direct commits (docs
  included). No `--no-verify`. Set `git config core.hooksPath tool/hooks` per
  clone.
- Gates: accessibility on any UI change; security on anything touching
  purchases; swift6 + testing standard. Purchase UI never merges without
  Michael's sign-off.
- No TestFlight push without Michael's explicit approval **and** a Kashe story
  chapter first (the chapter text is the `--notes` payload; ≤2500 chars).
- Parallel agents: isolated git worktrees, distinct pinned simulator UDIDs, one
  UDID reserved for CI only (`23F12FE1-…`).
