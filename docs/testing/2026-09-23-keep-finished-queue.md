# Keep finished episodes in Queue — September 23, 2026

StartTesting feature: `1f5ad0a4-fed6-46f5-b698-d8e7a7189489`.
The user approved the proposed default-off option, automatic skipping of finished
episodes, explicit replay, and independent download retention.

## Behavior

Settings → Playback → Keep finished episodes in Queue controls natural playback
completion. When on, finishing marks the episode played and dismisses it from
Inbox while preserving its Queue item identity and order. Unqueued playback does
not create Queue membership. When off, future natural completions remove their
Queue membership as before; already-retained finished items stay until removed.

Automatic selection and gapless preload skip played items, including when wrap
is off. The current item remains the positional anchor. Group-stop preferences,
sleep timers, Stop after this episode, and wrapping retain their existing rules.
With retention on, a requeued episode with a played timestamp is also excluded
from automatic candidates, including Play Next overrides. Mark unheard or choose
Play for an intentional replay. Explicit Previous/Next navigation still follows
the displayed Queue and can select a retained episode.

Manual Mark as played and next keeps its existing removal behavior. Manual
removal and Clear Queue preserve the played state of retained finished episodes;
neither action is an implicit Mark unheard. Download deletion remains controlled
by the existing Downloads setting. Folder-run natural completion applies the same
rule only to an episode already in Queue; its separate run history still advances.

## iCloud companion change

The existing remote Queue application unconditionally changes a queued episode
status to inQueue, even after played-state reconciliation marks it played. That
would undo the new retained completion state. A regression test covers this case.

The proposed companion change in CloudProjection.swift is to assign inQueue only
when the episode is neither already inQueue nor played. No membership, conflict,
migration, recovery, or persistence-schema behavior needs to change. Explicit
approval for this protected sync scope has been requested and is pending. This
change has not been applied; do not install this incomplete feature yet.

## Verification

Initial focused run: 148 tests passed, including QueueRepository,
AdvancedPlayback, FolderRunIntegration, and the first 11 retention tests.
Latest focused review run: 150 unit tests passed, and the new iCloud regression
failed as expected before the companion fix (151 unit tests total). The native
setting off/on/off UI test passed separately in the same run. All 13 retention
tests passed, including opt-out after retaining and a heard Play Next override.

The second agent independently confirmed the iCloud failure as the sole release
blocker and found the remaining implementation consistent with the approved
behavior. It explicitly withheld phone-testing approval until the companion fix
and final verification. No new build was installed.

The folder-specific retention test calls the player's completion bridge directly;
existing folder integration tests cover the controller path. Selection tests also
exercise the algorithm used by preload; they do not measure real network buffering.

## Phone checks

1. Enable the option in Settings → Playback. Finish a queued episode and confirm
   it stays in place, is announced as played, and the next unheard episode starts.
2. Finish the last unheard episode with wrapping on: playback should stop rather
   than replay the retained finished rows.
3. Try a sleep timer ending with the episode and Stop after this episode. Both
   should stop while keeping the completed Queue row.
4. Replay a retained row explicitly, then remove it. Removal should leave the
   episode played. Clear Queue should also preserve completed status.
5. Turn the option off: previously retained rows stay and are skipped, while
   subsequent natural completions are removed.
6. Verify your chosen download-retention behavior and confirm an iCloud refresh
   does not turn retained finished episodes back into unheard ones.

Physical acceptance is pending. No TestFlight distribution is authorized.
