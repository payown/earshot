# Folders Phase 4 — Playing-from-folder design

## Scope

Task 3 adds session-local folder context to playback started by:

- **Play all** in a folder detail screen, using that exact folder (including a nested folder).
- **Play Group** on a Queue group when Queue grouping is **By folder**, using the group's top-level folder.

Playing an individual episode from a folder screen is an ordinary episode start and does not set folder context. Podcast-group and Unfiled Queue groups do not set it either.

## State

`PlayerService` will expose an observed `PlaybackOrigin?`. The only v1 origin is `.folder(PersistentIdentifier)`.

- It is memory-only: no SwiftData property, migration, settings value, Queue mutation, or episode mutation.
- It stores identity rather than a name. Now Playing resolves the live folder and full breadcrumb path, so renames update naturally and deleted folders cannot leave stale text.
- Relaunch can restore the last episode, paused, but always starts with no origin.

## Transition contract

| Event | Result |
| --- | --- |
| Folder Play all / folder Queue Play Group | Set or replace with that folder |
| Any other deliberate episode start | Clear |
| Pause, resume, seek, buffering, interruption, or route change | Retain |
| Automatic completion advances within the origin subtree | Retain |
| Mark-played/remove-current advances within the origin subtree | Retain |
| Any advance crosses outside the origin subtree | Clear |
| Playback stops with no next episode | Clear |
| Active folder or containing deleted subtree is deleted | Clear |
| An unrelated folder is deleted | Retain |
| Relaunch restore | Clear |

Before every Queue advance, `PlayerService` will resolve whether the next episode's podcast is currently in the origin folder subtree. This prevents “Playing from News” from following playback into an unrelated Queue group.

## Player API wiring

- Ordinary `play`, preview, bookmark, notification, episode-row, podcast binge, flat Queue, podcast-group Queue, and Unfiled Queue starts pass `.started(nil)`.
- Folder Play all and folder-group Queue starts pass `.started(.folder(id))` through the existing user-initiated play path, preserving queue insertion and the Open Player on Play preference.
- Natural and explicit Queue advances pass `.advanced(nextEpisodeBelongsToOrigin:)`.
- Every unload/finished-without-next path passes `.stopped`.
- Launch restore passes `.restoredAfterRelaunch`.
- Folder deletion posts the identifiers removed after the repository persists the transaction; the player immediately applies `.foldersDeleted(ids)`, while Now Playing's live folder lookup independently prevents a stale control from rendering.

The pure transition function and its tests land before this wiring so every call site follows one policy.

## Now Playing and navigation

When the live origin folder resolves, Now Playing shows one 44-point button immediately after the episode/show information:

> Playing from News › Daily

The visible text is also its concise VoiceOver label. Its hint is “Opens this folder.” No separate icon or duplicated accessibility value is exposed.

Activating it dismisses Now Playing, switches to Library, and opens that folder detail. Root navigation resolves the identifier at activation time. If the folder no longer resolves or a host does not provide folder navigation, the control is omitted; no dead button is presented.

The episode title remains initial VoiceOver focus when Now Playing opens. The origin button becomes the next meaningful stop after the show information, without changing artwork or transport rotor order.

## Verification

- Pure tests cover every transition in the table, including replacement, unrelated deletion, and advancement across a folder boundary.
- Focused player, Queue grouping, folder repository, and Now Playing label tests run after wiring.
- Device testing covers folder Play all, Queue folder Play Group, automatic advance within and outside the folder, normal episode replacement, folder rename/deletion, relaunch, button speech, focus order, and return navigation.
