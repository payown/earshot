# Build 216 compact-projection evidence

## Device and build

- Earshot 1.2.0 (216), Release configuration
- Physical iPhone 17 Pro Max (`iPhone18,2`)
- iOS 27.0 (`24A5408d`)
- Installed and launched successfully on 2026-08-22 Pacific time

## Retained seed marker

The build-216 durable marker journal retained one complete reconciliation pair
after the app launched:

- Run ID: `49967455-047A-4A0C-AE57-EB2208AF5157`
- Duration: 0.316348667 seconds
- Podcasts: 1,085
- Episode states: 178
- Queue items: 146
- Settings: 19
- Bookmarks: 3
- Listening sessions: 580 total projection rows
- Folders: 3

## Listening-session semantic convergence

A read-only copy of the application and compact-projection store families was
collected after reconciliation. The comparison used the same semantic fields as
`CloudProjectionCoordinator`: canonical feed URL, optional episode GUID,
nonnegative duration, exact speed, and exact session date.

| Measurement | Result |
| --- | ---: |
| Local listening sessions | 229 |
| Active listening-session projections | 233 |
| Local sessions with an exact active semantic match | 229 |
| Local sessions missing from the active projection | 0 |
| Duplicate active semantic groups | 0 |
| Active remote projections without a local match | 4 |
| Listening-session tombstones retained | 347 |

Every local session is therefore accounted for by an exact active semantic
projection. The four additional active remote contributions are not evidence of
duplicate backfill, and no active semantic group is duplicated.

## Integrity and privacy

- Application store `PRAGMA integrity_check`: `ok`
- Compact-projection store `PRAGMA integrity_check`: `ok`
- The analysis was read-only and recorded aggregate counts only.
- No podcast, episode, session, or account content is included in this artifact.

This satisfies the remaining physical semantic-count acceptance evidence for
[#819](https://github.com/payown/earshot/issues/819).
