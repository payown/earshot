# Phase 1 empty baseline

Captured: 2026-08-08 15:03:13 -0700

## Independently verified

- Mac Earshot process count: 0.
- Mac application container present: no.
- Mac Application Scripts files: 0.
- Mac application stores present: 0.
- Mac compact projection stores present: 0.
- Mac downloads present: 0.
- Mac podcasts: 0.
- Mac episodes: 0.
- Mac queue items: 0.
- Mac listening sessions: 0.
- Mac bookmarks: 0.
- Mac folders: 0.
- Mac settings: 0.
- Mac schema version: none; no store has been created.
- Build-161 fixture base-store SHA-256:
  `319de2c6934f20ce2878d870c1ae0a777244de037243a9e1b88665fe77e9646a`.

The former 1.3 GB Mac application container is recoverable at
`~/.Trash/Earshot-Mac-Phase1-2026-08-08-1126`.

## User-confirmed CloudKit Console operation

- Container: `iCloud.media.payown.earshot`.
- Environment: Development.
- Operation: Reset Environment.
- Console result: development schema reset to Production.
- Deploy Schema Changes was not used.
- Production was not written.

## Verification boundary

No CloudKit management token is installed. The local development CloudKit cache
was removed with the Mac application container. Server-side development record
counts and the resulting server schema cannot be independently queried from this
host. The zero-record conclusion relies on the successful CloudKit Console reset,
whose defined operation deletes development data while resetting its schema to
the production schema.
