# ADR 003: SwiftUI takes over the Flutter bundle id with a one-time local import

- **Status:** Accepted. Supersedes the "no Flutter→SwiftUI import" decision in
  ADR 002 (the clean, versioned SwiftData store from ADR 002 still stands for
  all go-forward data).
- **Date:** 2026-06-21
- **Deciders:** Michael Babcock (Payown Media LLC)
- **Issues:** #393 (bundle id unification), #394 (first-run import). Closes the
  approach tracked in #354 / #376 (App Group crossover), now dropped.

## Context

ADR 002 assumed the SwiftUI rebuild would ship under a distinct bundle id
(`media.payown.earshot.swift`) so it installed *alongside* the Flutter app, and
that no data would be imported. That forced the migration to use an App Group
shared container plus a Flutter-side export writer plus Apple Developer portal
registration — brittle, cross-app, cross-release, and verifiable only on device.

Two facts changed the calculus:

1. **Flutter never released and has no production users.** There is no
   production cutover to protect and no large user base to migrate. The only
   data anywhere is a small TestFlight beta group's subscription lists.
2. The auto-migration only ever moved the **subscription list** — exactly what
   OPML export/import already does.

## Decision

The SwiftUI app takes over the **same bundle id** as the Flutter app
(`media.payown.earshot`). Because an over-the-top update keeps the same iOS
sandbox, the Flutter drift database is still present at `Documents/earshot.db`.

On first launch the SwiftUI app reads that database's `podcasts` table directly
via SQLite3 and subscribes to each feed once, silently:

- A fast local read decides "returning user" vs "new user." Returning users
  skip onboarding and land in a populated Library; the network subscribe runs in
  the background. VoiceOver gets a "Welcome back" cue and an "Imported N shows"
  confirmation.
- The import is marked complete only on success, so a failed (offline) run
  retries on the next launch rather than stranding a returning user.
- Only subscriptions migrate (not queue, played state, or positions); every
  other field is re-derived from the live feed. OPML import is the manual
  fallback.

This removes the App Group, its entitlement, the Apple-portal registration, the
Flutter-side export writer, and the dedicated Beta build config / `IS_BETA_BUILD`
flag — none of which are needed when the sandbox is shared.

The leftover `earshot.db` is left in place after import (a few MB); optional
cleanup once the completion flag is set is a minor follow-up.

## Consequences

- Beta testers keep their subscription list automatically on the switch, with no
  steps and nothing leaving the device.
- The first SwiftUI upload's build number must exceed the Flutter TestFlight
  high-water mark (build 112 at time of writing) or App Store Connect rejects it.
- **Device verification is required and cannot be done in CI:** install the
  current Flutter TestFlight build, create real data, install the SwiftUI build
  *over* it (no uninstall), and confirm the container persists and the import
  runs — ideally against a large (100+ feed) library.
- The Flutter source tree (`lib/`, `ios/`, `tool/`) is no longer a shipping
  target. Retiring it entirely is a separate, later decision.
