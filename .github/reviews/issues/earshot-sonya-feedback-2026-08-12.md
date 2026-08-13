# Sonya beta feedback triage — Earshot

> Generated 2026-08-12 from Sonya's email and Michael's reply.
> Quill Cast-specific comments were excluded at Michael's request.

## Outcome

Three new issues were required. One request was added to an existing issue. The remaining reports describe features already present in build 191 or defects already addressed by current code.

| Feedback | Disposition | Tracking |
| --- | --- | --- |
| Assign a podcast to a label/folder | Implemented | Folder actions and podcast settings shipped through #754, #756, #757, and #761. |
| ACV Community becomes sluggish with 4,000+ episodes | Addressed, retain physical regression coverage | Current ingestion and presentation paths are bounded; large-library heat/responsiveness remains tracked by #820. |
| Add/remove Quick Actions | New issue | [#834](https://github.com/payown/earshot/issues/834) |
| Export audio from Queue | Implemented | Shared export/download-then-share work is covered by #363, #401, #553, and #689-era code. |
| Search within a podcast by episode title/description | Existing issue updated | [#457](https://github.com/payown/earshot/issues/457) |
| Delete a download when played | Implemented | Build 191 Downloads settings. |
| Delete all downloads | Implemented | Build 191 Downloads screen/settings. |
| Download all in Inbox and Queue | New issue | [#835](https://github.com/payown/earshot/issues/835) |
| Only 10 recent episodes are reachable | New 1.1 correctness issue | [#833](https://github.com/payown/earshot/issues/833) |
| Auto-download queued episodes | Implemented | Existing auto-download-queue behavior, enabled by default. |

## Important findings

The 10-episode report is confirmed by code, not merely a feature suggestion. Initial OPML and synced-shell ingestion each cap the local catalog at ten rows; ordinary refresh only ingests newer rows. No historical paging path exists, so old episodes can remain permanently inaccessible. Issue #833 is therefore in the Earshot 1.1 milestone and requires bounded, restartable paging without reclassifying history as new Inbox content.

Quick Actions already have a VoiceOver-operable reorder screen. However, omission is not persistent: the repository appends every missing action. Issue #834 correctly scopes the request as enable/disable plus reorder, not a rebuild of the existing rotor system.

Podcast-detail search can use feed title and description metadata and does not require transcripts. The feedback was added to #457 rather than duplicated.

## Release relationship

Only #833 is classified as a 1.1 correctness blocker from this email. Issues #834 and #835 are useful enhancements but are not automatically release blockers. The independent iCloud release gate remains #817 and `docs/releases/1.1.0-icloud-release-gate.md`.
