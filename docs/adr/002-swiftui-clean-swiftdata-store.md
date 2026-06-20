# ADR 002: SwiftUI rebuild ships a clean, versioned SwiftData store

- **Status:** Accepted
- **Date:** 2026-06-19
- **Context:** SwiftUI rebuild (`swift` branch), Phase F2 (issue #337)

## Context

The production Flutter app stores all user data in a drift/SQLite database
(`earshot.db`, schemaVersion 16) inside its app sandbox. The SwiftUI rebuild
ships with bundle id `media.payown.earshot.swift` (note the `.swift` suffix) so
it installs *alongside* the Flutter app on a device rather than replacing it, per
the project rule that the Flutter TestFlight build must stay untouched.

Two consequences follow:

1. A separate bundle id means a separate sandbox container. The SwiftUI app
   cannot read the Flutter app's `earshot.db` without a shared App Group (which
   would require changing the Flutter app's entitlements) plus a raw-SQLite
   import shim, since SwiftData and drift use different store formats.
2. During the rebuild, "existing on-device data" most meaningfully refers to a
   prior *SwiftUI* build's SwiftData store, not the Flutter database.

## Decision

The SwiftUI app uses a clean SwiftData store defined behind a `VersionedSchema`
(`EarshotSchemaV1`) with a `SchemaMigrationPlan` (`EarshotMigrationPlan`). The
`ModelContainer` is configured with the migration plan and is never deleted and
recreated; schema changes add a new version + migration stage (lightweight where
possible). Opening the persistent store is wrapped in do/catch and falls back to
an in-memory container with a logged error, so a migration failure can never
dead-end the app on launch.

No Flutter (drift/SQLite) -> SwiftUI (SwiftData) data import is implemented now.

## Consequences

- Existing SwiftUI-build data survives upgrades via the migration plan.
- A user moving from the Flutter app to the SwiftUI app would start fresh today.
- If/when SwiftUI replaces Flutter in production, a one-time cross-engine import
  (App Group + raw-SQLite reader mapping the drift v16 schema into SwiftData)
  becomes a separate, scoped task. The SwiftData models already mirror the
  drift v16 domain to keep that future import lightweight.
