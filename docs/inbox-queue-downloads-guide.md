# Inbox, Queue, and Downloads guide

## What each screen is for

Inbox helps you review newly arrived episodes and decide what to listen to. Clearing it dismisses the episodes currently in that Inbox scope. They remain in their podcasts, and new arrivals can appear after a later refresh.

Queue is your listening order. Adding an episode to Queue can request a download if Auto-download queued episodes is on. An episode can be queued before its download finishes.

Downloads contains completed audio stored on this device. An episode can be downloaded without being in Inbox or Queue. Inbox and Downloads counts do not need to match.

Recently Expired appears in Downloads for episodes that automatically expired from Queue. You can restore them for seven days before their audio is removed. Downloads filters and folder selection can affect which episodes you see.

## Set up automatic downloads

1. Open Settings, then Inbox. Choose how many recent episodes should enter Inbox when you follow a podcast. Opt-in podcasts only lets you limit future Inbox arrivals to podcasts you explicitly include. These controls manage Inbox membership, not offline audio.

2. Open Settings, then Downloads. Download on Wi-Fi only holds new download requests until Wi-Fi is available. Earshot resumes waiting requests when it detects Wi-Fi; iOS controls background scheduling, so completion is not instantaneous.

3. Find Auto-download new episodes per podcast. With VoiceOver, focus this adjustable control and flick up or down to choose Off, 1, 3, 5, or 10. It defaults to Off. The chosen count applies per podcast when following it and to newly found episodes after refresh. Those episodes can go to either Inbox or Queue. This is not a total storage limit and does not automatically download every older episode already in Inbox.

4. Choose whether to keep Auto-download queued episodes on. It defaults to On and requests audio for episodes you add to Queue, including older episodes. This is separate from the new-episode setting. Both settings respect Wi-Fi-only.

5. Choose whether to enable Delete downloads when done. It defaults to Off. When on, Earshot removes downloaded audio when you finish an episode, mark it played, deliberately remove it from Queue, or clear it from Inbox using Clear inbox.

## Download the current Inbox or Queue

1. Open Inbox or Queue and check the folder and search scope. Clear a search if you intend to download every eligible episode in that scope.

2. Open Inbox options or Queue options, then activate Download all. When a search is active, the command names the filtered scope.

3. Listen to the confirmation and activate Download N episodes, where N is the episode count. Opening the options command alone does not start the requests. Cancel leaves them unchanged.

4. Earshot requests at most 50 eligible episodes at a time. Already downloaded, downloading, and Wi-Fi-waiting episodes are skipped. Failed episodes can be requested again. If the confirmation says more are left for another batch, repeat Download all to request the next batch.

5. The announcement confirms that requests were prepared. It distinguishes downloading, waiting for Wi-Fi, and requests that could not start. The files may still be transferring. Open Downloads, then Download activity to check them.

Download all is a one-time command. Episodes arriving tomorrow will only download automatically if your automatic download settings request them.

## Check progress and retry failures

Open Downloads, then Download activity. You can also reach Download activity from Settings, Downloads. Its summary covers all podcasts on this device, regardless of the folder, search, or played filter used in Downloads.

Downloading means Earshot has requested a transfer from iOS. It may still be connecting or waiting for system scheduling. Waiting for Wi-Fi means the Wi-Fi-only setting is holding the request. Download failed means the request did not succeed. Downloaded means completed audio is stored locally.

The summary and episode states update without announcing every completion. Activate Read download status to hear one current summary. Include completed downloads lets you review completed requests alongside other states. Otherwise, the list shows downloading, waiting, and failed episodes. Use Show more download requests to reveal more entries.

Find a failed episode and activate Retry download for that episode. Retry failed downloads offers a confirmation for up to 50 failures across all podcasts. Any additional failures remain available for another batch. Retries still respect Wi-Fi-only. A failed episode may still stream when played, but streaming needs a connection.

Notify when downloads finish, in Settings, Downloads, optionally sends local notifications when files finish. That setting is separate from the spoken status summary.

## Clear Inbox and manage storage

Clear inbox hides the current Inbox episodes without marking them played or removing their podcasts. If Delete downloads when done is on, Clear inbox also removes those episodes' downloaded audio. If that setting is off, their downloaded audio stays on this device. You can still find the episodes in the podcast's episode list. Clearing Inbox does not prevent future episodes from arriving.

Dismissing an individual episode from Inbox is different from Clear inbox: it hides that episode without deleting its downloaded audio or marking it played.

Clear all downloads removes local audio and cancels active or Wi-Fi-waiting requests. It does not dismiss Inbox episodes or remove podcasts. Removing an individual download likewise removes the file rather than the episode. A later manual or automatic request can download an episode again.

Marking an episode played removes it from Inbox. Delete downloads when done also removes its completed audio if that setting is on. Removing an episode from Queue can also remove its completed download when that setting is on. Turning the setting off lets you manage downloaded audio yourself.

## When Inbox and Downloads counts differ

For example, 19 Inbox episodes and 9 Downloads means 19 episodes are available to review and 9 completed downloads are visible. It does not, by itself, tell you what happened to the remaining requests.

First, open Download activity. Check for downloading, waiting for Wi-Fi, or failed episodes. Retry failures if appropriate. Check that you completed the Download N episodes confirmation and requested any deferred batches.

Next, check the search, folder, and All or Unheard filter in Downloads. Those controls can hide completed files. Also check Delete downloads when done and whether you previously used Clear inbox, cleared downloads, marked episodes played, or removed them from Queue. With Delete downloads when done on, clearing Inbox can explain why previously downloaded audio is no longer in Downloads.

If requests remain stuck or fail again, use Settings, Help & About, Send Feedback. Include the app version and build, affected podcast and episode names, the states shown in Download activity, roughly when you requested them, whether Wi-Fi-only is on, and whether individual retries work. These details help distinguish a server or connection problem from an app problem.

## About this guide

This guide accompanies the Download activity update after build 256. Earlier builds may not have Download activity or the updated request announcements. The same guide is bundled in Help & About so it remains available offline.
