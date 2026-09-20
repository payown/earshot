# TestFlight preparation — September 20, 2026

Michael confirmed the requested phone checks passed and then authorized merging PR #979 and distributing build 267 to both TestFlight groups.

## Library unplayed counts

Library rows now display and speak the count immediately after the podcast title: “Sawbones, 12 unplayed episodes.” One episode uses the singular; a caught-up show says “0 unplayed episodes.” Existing author, read-only disclosure, description, traits, and actions remain in place.

Counts use the same `playedAt == nil` condition as the podcast screen. SQLite counts run on a utility worker with its own context; no episodes are materialized and no `Podcast.episodes` relationship is read. Returning to Library, subscription changes, refresh completion, CloudKit updates, and played-state changes refresh the snapshot. Requests are coalesced and cancelled when superseded. Playback-position checkpoints do not trigger recounting.

## BBC finding: unresolved provider transport

Live checks from this Mac on September 20 found HTTP enclosure URLs throughout the four reported feeds:

| Podcast | Feed ID | HTTP enclosures | Latest episode VPID |
| --- | --- | --- | --- |
| In Touch | b006qxww | 470 / 470 | p0p9r146 |
| You're Dead to Me | p07mdbhg | 289 / 289 | p0p54jsg |
| Comedy of the Week | p02pc9x6 | 51 / 51 | p0p9669m |
| The Infinite Monkey Cage | b00snr0w | 239 / 239 | p0mp40k1 |

Feed URLs have the form `https://podcasts.files.bbci.co.uk/FEED_ID.rss`.

For each latest episode, HEAD and GET requests with `Range: bytes=0-0` were tested using both a scheme-only HTTPS upgrade and the BBC selector's `/proto/https/` path. The client refused HTTP redirects. All routes ultimately requested an HTTP destination on `bbc.pdn.tritondigital.com`. Upgrading the final signed URL to HTTPS returned 403 in all four samples, for both methods. No signed query parameters were altered. The BBC metadata selector also published an HTTPS connection for each sample, but fresh GET checks of all four published connections still encountered the same HTTP downgrade.

Code agrees with the report: `MediaHTTPSProbe` rejects a final HTTP destination, so `PlayerService` requests playback approval. `DownloadManager` upgrades the initial URL, but its URLSession transfer remains subject to App Transport Security. Playback approval does not enable insecure downloads. No verified secure route was found; no security exception or warning suppression is included. This evidence is from the Mac, not a successful or failed iPhone download measurement. Regional delivery may differ.

StartTesting bug: `e759e5c0-1de5-4496-a617-aff822794a14` (high priority, remains open). Related GitHub follow-up: #709.

## Combined phone checks

1. In Library, compare the spoken count with the total inside several podcasts, including a caught-up show and one with exactly one unplayed episode. Flick rapidly through a large Library; verify responsiveness and focus.
2. Mark an episode played, return to Library, and verify the count decreases. Mark it unplayed and verify the count increases. Check completion during playback and a feed refresh too.
3. In Inbox, unfollow a test podcast, then flick backward and forward. Its episodes should disappear, focus should remain useful, and the phone should stay responsive.
4. In a Queue grouped by folder, sort one folder oldest to newest. Verify its order and playback sequence without changing the others. Check “Added Episodes,” “Remove after: Unlimited” help, and “Save as Lineup” help.
5. Try playback and downloading for one affected BBC show and one known-working HTTPS show. For BBC, record the warning and download result; this issue remains open. Canceling the warning must leave playback stopped. Any decision to allow playback is the user's choice.

## Validation results

- Focused initial run: 17 tests, zero failures.
- Final combined EarshotTests run: 2,382 tests reported, 29 skipped, zero failures. The two documented StoreKit suites were excluded as required; purchases still require physical-device Sandbox testing when changed.
- Final Release build succeeded under Xcode 27.0 (27A266a); strict signature verification passed.
- Installed version 1.2.3 (266), including code revision `a4345325`, on Michael’s iPhone. No TestFlight upload.
- Installed executable SHA-256: `12eebc1f845b994de7f3fdefd59882707c934838e907cdf2bfd9c8c45c1f4e88`.
- Michael confirmed Library counts and updates, responsive navigation and Inbox unfollowing, folder sorting, and the three wording changes passed on his phone. BBC transport remains an unresolved issue.

PR #979 passed CI and was merged. The BBC issue remains high/open and is disclosed in the build 267 testing notes.
