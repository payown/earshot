# Download activity validation

Issues: #958 and #959. Implementation based on main at `7b1e855` (build 256).

## Automated coverage

Verified on 2026-09-05 with Xcode 26.6 and the iPhone 17 iOS 26.5 simulator: 119 focused unit tests and both UI tests passed. The initial unsigned UI runner could not launch; using Xcode's normal simulator signing resolved the launch failure. No project signing settings changed.

DownloadActivityTests covers 19 accepted requests followed by nine successful terminal events, six failures, and four continuing transfers. It checks the live count projection, reopens a data context to verify durable failure state, and retries only the six failures. Additional tests cover Wi-Fi waiting and resumption, duplicate calls while on and off Wi-Fi, invalid media URLs, cancellation, the 50-request limit, and bundling the offline guide.

The focused regression run includes DownloadManagerTests, DownloadScanBoundsTests, DownloadsInboxLogicTests, and EpisodeRowLabelTests. UI coverage opens Download activity through Downloads, observes a delayed failure, exercises the batch retry confirmation, and opens the guide from download settings at the largest accessibility text size.

## Physical-device checks before release

1. With VoiceOver on, use Inbox options, Download all, and the second Download N episodes confirmation. Confirm the announcement describes requests and directs you to Download activity.

2. In Downloads, open Download activity. Read the summary and several rows. Downloading, Waiting for Wi-Fi, Download failed, and Downloaded should be distinguishable. Use Read download status while several downloads finish; individual completions should not interrupt or build a queue of speech.

3. With Wi-Fi-only enabled and Wi-Fi unavailable, request a download. It should remain Waiting for Wi-Fi. Restore Wi-Fi and verify it progresses and finishes. Background the app, return, and repeat after relaunch to check iOS background scheduling on the device.

4. Retry an episode whose publisher returns an error. It should remain visibly failed if the error persists. Retry failed downloads must confirm an exact count no greater than 50 and leave additional failures available. Verify that the retry control remains understandable with VoiceOver as the row's state changes.

5. Turn on Include completed downloads. Completed requests should also appear in the usual Downloads view when its folder, search, and played filters allow them.

6. Open Settings, Help & About, Inbox, Queue, and Downloads guide. Read it offline and navigate its section headings using VoiceOver. Repeat at a large text size. The guide must explain the separate clear actions, automatic settings, second confirmation, and retries.

## Limits of the original report

The customer's build-252 report does not include episode names, per-episode states, or transfer logs. It cannot establish which requests failed or whether the second confirmation was completed. The new status surface supplies that missing evidence for future reports. Automated terminal events test the app's state handling, but do not reproduce that customer's network or iOS background scheduling.
