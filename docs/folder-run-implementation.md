# Folder backlog playback

Tracking: [folder-wide oldest-first playback, #944](https://github.com/payown/earshot/issues/944).
The tested foundation was merged in #961; the integration adds the working UI,
catalog preparation, player, recovery, and reset lifecycle.

## How to use it

1. Open Library, then Folders, and open a folder.
2. In Folder listening actions, choose Play unheard oldest first. The same
   action is available on the folder row.
3. Confirm Check feeds and prepare. Earshot checks each followed show's feed once,
   including shows in subfolders. You can leave the status screen while it works.
4. Runs with more than 50 episodes ask you to confirm the actual count before
   starting. Choose Not now to leave the prepared run ready for later.
5. Return through Folder run status in Folders to read counts, resume, or cancel.
   Preparing another folder asks permission to replace an unfinished run.

Eligibility means unplayed and not future-dated, regardless of Inbox dismissal,
download status, Queue caps, or saved position. Ordering is publication date,
oldest first, with missing dates last and canonical feed/GUID as deterministic
tie breakers. Membership and ordering are frozen after preparation; new arrivals
require preparing a new run. Renaming or deleting the folder does not destroy
the prepared run. Unfollowed shows and deleted or already-played episodes are
skipped when their turn arrives.

Preparation includes stored episodes and older episodes still exposed by RSS.
It cannot restore a publisher's unavailable archive. Failed or empty feeds and
fully numbered feeds starting above episode one are flagged as unavailable or
possibly incomplete; stored episodes from those shows remain eligible. Imported history
does not arrive in Inbox, send notifications, or trigger automatic downloads.
Episodes stream unless already downloaded; preparation is not Download all.

The run is separate from the normal Queue. Unrelated Queue order remains intact;
completing a queued episode removes that duplicate normally. Completion and
download cleanup use the existing played-episode policy. Normal Queue playback
resumes after completion or cancellation of an actively playing run, subject to
the existing continue-after-episode setting. Cancelling a paused/preparing run
does not interrupt unrelated audio.

Pause, interruptions, sleep timers, and stop-after-current retain the run.
Deliberately playing something else pauses it. Relaunch restores active playback
paused at the saved position, never starts audio automatically, and cancels
unfinished preparation. A failed stream retains its place and unplayed state:
Resume retries, while Skip unavailable folder episode explicitly skips it.
An explicit HTTP 404 or 410 in the player's error log skips automatically;
ambiguous failures never silently advance or mark an episode played.

## Ownership and durability

- FolderRunController owns only main-actor presentation and the current episode.
  Tracked operations cancel and drain predecessors before replacement or reset.
- FolderRunCatalog owns off-main catalog queries/imports with short-lived contexts,
  canonical subtree deduplication, one RSS fetch per feed, and 100-row batches.
  GUID pagination uses lexical ordering for both the sort and cursor predicate;
  natural string ordering would skip numeric GUIDs after the first page.
- FolderRunStore owns a separate local V1 SwiftData manifest, CloudKit off. It
  numbers 100 model rows per page and returns at most eight identities per window.
  No thousands-item Queue or cross-actor SwiftData models are introduced.
- Publication ordering is frozen. The player re-resolves authoritative played
  state, availability, and position before each episode. Completion saves played
  state before advancing the manifest: after a crash between those two stores,
  recovery skips the played item instead of replaying it.
- Replaced manifests are pruned in bounded batches. The run directory is excluded
  from backup. Delete local data cancels/drains the controller before the existing
  reset transaction removes FolderRuns. Michael explicitly approved this narrow
  SettingsReset extension on September 5, 2026.
- Store-open failures are surfaced; no silent deletion or in-memory fallback.
  Only DEBUG screenshot fixtures and explicit test injection use in-memory runs.
- The shared V12 schemas, signing, entitlements, and existing playback controls
  are unchanged. Runs are device-local; they do not sync across devices.

## Verification and release gate

Automated coverage includes nested/deduplicated membership, a 3,005-episode RSS
import, all 3,000 manifest entries consumed, deterministic numeric GUID ordering,
partial-feed failure, cancellation/reset, saved position, relaunch, folder rename
and deletion, played/unavailable skips, normal Queue preservation, and real local
audio finishing with stop-after-current followed by resumption. The UI test
prepares 60 historical episodes, verifies the count confirmation, and cancels.

Before release, validate on Michael's phone with VoiceOver:

1. Prepare a large real folder while browsing Library and using the keyboard;
   check responsiveness, counts, cancellation, and return to status.
2. Listen across shows while backgrounded, lock/unlock, interrupt with another
   audio app, and verify pause/resume and saved places after relaunch.
3. Test sleep timers, stop-after-current, missing audio retry/skip, and completion
   returning to the original Queue without replaying duplicates.

Simulator tests do not establish on-device VoiceOver latency or long-running
background reliability. Keep #944 open until that acceptance pass. No App Store
upload or release is part of this integration.
