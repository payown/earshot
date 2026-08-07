# Delete all local data: approval required

Status: **Gate 3 fired. No fix is implemented in shipping code.**

Measured gate inputs:

- `T_current = 145.774626 seconds` for the required Phase 3.1 real-store copy.
- `T_best = 121.419712 seconds`, candidate (a), for the fastest successful
  Phase 3.4 real-store candidate that preserved the current database scope.
- Candidate (b) took 153.079173 seconds on the real copy.
- Candidate (c), SwiftData batch delete in dependency order, failed after
  0.005999 seconds with `NSCocoaErrorDomain Code=134060`; it deleted no rows.
- Candidate (d), container teardown and store-file removal, took 0.027738
  seconds on the real copy but is not scope-equivalent: it also deleted all
  `LocalPodcastState`, `LocalEpisodeState`, and `LocalAppSetting` rows and the
  split/repair markers held there.

The 3.0-second threshold is a **VoiceOver usability judgment supplied by the
task**, not an empirical measurement. Moving the current operation off the main
actor would replace a watchdog kill with roughly two minutes of unexplained
silence. That is not approved.

## Decisions requiring explicit user approval

1. Whether to add a dedicated destructive-operation screen or overlay while a
   long reset runs. This changes visible UI, VoiceOver focus, and navigation.
2. The exact progress, heartbeat, failure, partial-failure, and completion copy.
   Every draft below is a new or changed user-facing string except the existing
   completion announcement.
3. When VoiceOver focus moves to the progress status, whether it remains there,
   and where focus lands on success or failure.
4. Whether a reset can be cancelled, and the point after which cancellation is
   disabled. Cancellation semantics must match the persistence transaction.
5. Whether a second reset control is disabled or ignored while reset is active,
   and what, if anything, VoiceOver announces for a second activation.
6. Heartbeat cadence and whether heartbeats interrupt other speech. A proposed
   ten-second cadence is only a draft.
7. Whether “all local data” expands to include the V10 device-local models
   `LocalPodcastState`, `LocalEpisodeState`, and `LocalAppSetting`, which the
   current reset omits.
8. Whether the verified migration snapshot survives a Settings reset. The
   current direct-removal reset does not invoke migration journal, quarantine,
   or verified-snapshot machinery.
9. Whether deleting both store files is acceptable. It is the only measured
   sub-three-second candidate, but it widens database scope and requires safe
   replacement of the live `ModelContainer` and every dependent context.
10. What result is acceptable if persistence commits but download or artwork
    deletion fails. A partial reset cannot truthfully announce either complete
    success or “nothing was removed.”
11. Whether preferences outside SwiftData should be deleted. The current reset
    deletes `AppSetting` rows but does not clear `UserDefaults` generally.
12. Whether downloaded audio and artwork deletion remain in scope exactly as
    today, or whether “all local data” is intended to cover additional caches,
    snapshots, journals, quarantine directories, or other container state.

The user’s tolerance for losing his own test library authorizes no shipped
scope change. It does not answer any deletion-scope question for public users.

## Draft wording — approval required, not present in shipping code

These strings are proposals only. They have not been added to source, tests,
localizations, accessibility labels, values, announcements, or focus logic.

- Initial progress announcement and visible heading: **DRAFT:** “Deleting all
  local data.”
- Non-determinate visible status: **DRAFT:** “Deletion in progress.”
- Heartbeat announcement after each approved interval: **DRAFT:** “Still
  deleting all local data.”
- Failure before any destructive commit, only when rollback is proven:
  **DRAFT:** “Local data could not be deleted. Nothing was removed.”
- Partial failure after persistence committed but one or more files survived:
  **DRAFT:** “Some local data could not be deleted.”
- Completion: retain the existing shipping announcement unchanged unless the
  user approves different wording: “All local data deleted. Podcasts you
  follow and downloads removed.”

## VoiceOver behavior requiring approval

For an operation that legitimately lasts tens of seconds, the proposed behavior
is:

1. After the user confirms, present a stable, non-dismissable status surface and
   move VoiceOver focus once to its heading.
2. Announce that deletion started immediately. Do not leave the user in silence
   while destructive work is active.
3. Expose an indeterminate progress indicator with an approved accessible label
   and value. Do not invent a percentage that the persistence layer cannot
   measure truthfully.
4. Provide non-interrupting heartbeat announcements at an approved cadence
   while the operation remains active.
5. Prevent a second reset attempt while the first is active. Any spoken response
   to a second activation requires approval.
6. On success, replace the status surface with a stable destination, move focus
   to an approved element, and speak the approved completion announcement once.
7. On failure, remain on a stable screen, move focus to an approved error
   element, and announce wording that accurately distinguishes rollback from a
   partial delete.

Every visible string, accessibility label/value, announcement, focus move,
heartbeat interval, and interruption policy in this behavior requires explicit
approval before implementation.

## Decision table

| Option | Measured completion | Database scope | What a VoiceOver user hears and does without approved UI changes | Failure modes | Risk |
|---|---:|---|---|---|---|
| (a) Current Podcasts-first object deletion, moved off-main | 145.774626 seconds in Phase 3.1; 121.419712-second second real sample | Deletes the current 11 mirrored model types; preserves all three local model types | Silence for about two minutes, then the existing success announcement; reset must reject a second activation | Large in-memory graph, save failure, filesystem failure after save, stale live contexts | Unacceptable silence; 998.922 MB measured peak RSS in Phase 3.1; no sub-three-second result |
| (b) Episodes-first object deletion, moved off-main | 153.079173 seconds real; 295.777705 seconds synthetic 1×40,000 | Same current database scope | Same long silence without new approved behavior | Same transaction/filesystem split; still per-object and shape-sensitive | Slower than (a) on the real copy; not gate-eligible |
| (c) SwiftData batch delete in dependency order | Did not complete: failed at 0.005999 seconds real and 0.005535 seconds synthetic | Intended to preserve current scope, but no successful result established it | Failure path only; no success announcement may be spoken | `NSCocoaErrorDomain Code=134060` relationship metadata error in split container; zero rows deleted | Not a viable measured remedy in current configuration |
| (d) Tear down container and remove both store sets | 0.027738 seconds real; 0.009515 seconds synthetic | Deletes mirrored models, all three local models, split/repair markers, and any other store rows; does not by itself delete audio, artwork, preferences, or snapshots | Near-immediate completion could retain existing announcement, but scope and live-container transition are unapproved | Unsafe if any context still uses removed stores; audio/artwork may fail after stores vanish; snapshot policy unresolved | Fastest and only measured sub-three-second option, but materially different semantics |
| Long-running (a), (b), or another scope-preserving algorithm plus approved status UI | Floor measured at 121.419712 seconds among successful candidates | Can retain current scope or adopt an separately approved scope | Immediate start announcement, truthful indeterminate status, approved heartbeats, accurate success/failure, stable focus | Must distinguish rollback from partial filesystem failure; background task interruption and relaunch recovery need design | Accessible in principle, but changes copy, focus, announcements, timing, and UI; approval required |

## Pure threading and sequencing changes that do not themselves change copy

If a long-running scope-preserving implementation is approved, these changes
can be separated from UI semantics:

- Perform persistence deletion in a dedicated persistence actor/private
  `ModelContext`, not on the main actor.
- Keep service shutdown, reset-in-progress state, and the final UI transition on
  the main actor.
- Reject a second reset attempt while one is active.
- Commit persistence successfully before deleting downloaded audio or artwork.
- Treat save and filesystem failures as failures; never announce success after
  either one.
- Replace or refresh the live container and dependent contexts only after
  destructive persistence work commits.

Those changes do not authorize any new spoken or visible behavior, and they do
not solve the measured two-minute silence by themselves.
