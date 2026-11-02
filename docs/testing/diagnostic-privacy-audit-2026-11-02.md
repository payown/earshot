# Earshot diagnostic privacy audit, November 2, 2026

StartTesting: `cb8fea95-4e72-45dd-8a93-8a9ae1acd4dc`. This is a code audit, not a report of a real log leak. Use only synthetic URLs, titles, and error text when testing it.

## Verified work

- Merged PRs #1013 and #1014 replaced raw URL, search-term, server content-type, and free-form transport diagnostics in HTTP, artwork, search, preview, and several subscription paths with fixed categories. Their synthetic-secret tests remain in the suite.
- PR #1036 head `eade3ff3` removes the remaining public `localizedDescription` and episode-title values in `DownloadManager` logs, and routes its error diagnostics through `NetworkDiagnostic.reason`. `HTTPClientRetryTests.testWrappedAndUnknownErrorDiagnosticsNeverExposeFreeFormText` checks that helper with a synthetic signed URL, query token, and custom NSError domain/description. This is a partial fix; its fresh CI is pending.
- Draft PR #1042 head `288377b1` removes episode titles and unrestricted error descriptions from `EpisodeExporter` and `BookmarkRepository` public logs. An iOS Simulator build passed; full CI and review remain. Export filenames and bookmark data are unchanged.

## Remaining audit map

The November 2 source search still finds public free-form `localizedDescription`, file names, or podcast/episode titles in these areas. A title or NSError description can be server or provider supplied, and may contain a private URL or token. The search is a risk inventory, not proof that a particular value reached a user's log.

- **Media and subscriptions:** `PlayerService`, `FeedRefreshActor`, `BackgroundFeedRefresher`, `SubscriptionRepository`, `OPMLFileImporter`, and `ExpirationService`. Prioritize network and file errors and public feed or episode titles. `EpisodeExporter` is covered by draft #1042, pending CI and review.
- **Persistence and local data:** `ModelContainerFactory`, `MigrationBackupManager`, `AppSettingsStore`, `CloudProjection`, `QueueRepository`, `InboxRepository`, `EpisodeRepository`, `FolderRepository`, and related save/fetch paths. An NSError description can contain a path or model value even when the direct log statement does not include a URL. `BookmarkRepository` is covered by draft #1042, pending CI and review.
- **UI and settings:** `MailComposeView`, `DataSettingsView`, and other picker/export failure paths. `SettingsReset` and purchase UI are protected by the repository guidance and require separate sign-off before edits.

Search command for the next pass:

```sh
rg -n 'localizedDescription, privacy: \.public|\.title, privacy: \.public|\.absoluteString, privacy: \.public|\.domain, privacy: \.public' Earshot
```

## Acceptance for a broader fix

1. Replace public free-form values with a fixed operation name plus safe category/code, or keep a value private when the diagnostic must retain it. Audit multi-line log statements and custom sink wrappers as well as single-line calls.
2. Use synthetic signed feed and artwork URLs, query tokens, server-supplied titles, and NSError descriptions/domains. Verify the emitted public diagnostic contains a useful operation and error category but none of the synthetic secret values. Keep the test sink isolated from real accounts and logs.
3. Run focused tests and full CI on the final head. For any new on-device logging test, use synthetic data only. Do not claim a production leak occurred or that the entire audit is complete after one module is changed.
