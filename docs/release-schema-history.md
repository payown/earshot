# Earshot release and store-schema history

This file is the durable source of truth for deciding which on-disk stores a
new Earshot build must open. Do not infer a migration floor from a remembered
release number, a planning document, or the newest TestFlight fixture.

## Evidence standard

The history below was reconstructed on 2026-08-06 from two independent sources:

- App Store Connect's build records identify the build numbers that were
  actually uploaded and their TestFlight state. Its App Store version
  relationship identifies build 155 as the binary attached to public version
  1.0.0.
- The repository version at each upload boundary identifies the database
  implementation and the exact schema version that a fresh install created.

Build-number bump commits alone are not treated as proof of an upload. For
example, build 158 exists in Git but does not exist in App Store Connect.

Build 165 is a local device-verification build only. It was never uploaded
to App Store Connect and reached no distribution channel. It is the first
build produced from corrected source at or after
fb45ede5f939cd18eeb5291a20e038bcda507911, and exists to give the phone a
pre-launch identity distinguishing it from the stale build-164 binary that
displayed the incorrect pre-V6 floor guard. Fresh stores: SwiftData V10.
Supported migration sources: V5 and V6.

Build 166 is the authorized reset-watchdog fix verification build, local only,
with fresh-store schema V10 and supported migration sources V5 and V6. It is
known-bad: the 2026-08-07 device reset crashed from the feed-refresh race and
must not be used for further testing.

Build 167 supersedes build 166 as the local device-verification build. It
contains commit `55a55cfc` on `agent/reset-feed-refresh-race`, which cancels
and awaits the active background feed refresh before file reset. Fresh-store
schema remains V10; supported migration sources remain V5 and V6. It is also
known-bad: the 2026-08-07 device reset crashed when the launch path reopened
store files while reset was moving them, and it must not be used for further
testing.

Build 168 supersedes known-bad builds 166 and 167 as the local
device-verification build. Its OPML path uses a bounded streaming pipeline:
up to six feeds are fetched concurrently, and each completed feed is written
and reported immediately instead of retaining every parsed feed until all
network work finishes. Fresh-store schema remains V10; supported migration
sources remain V5 and V6. Its six-feed concurrency still made the device UI
unresponsive during a real 60-feed OPML import, so it is known-bad for further
OPML testing.

Build 169 supersedes build 168 for local OPML device verification. It reduces
bulk-import concurrency to two feeds, saves after two newly inserted feeds, and
cooperatively yields during large episode-insertion loops to preserve foreground
and VoiceOver responsiveness. Fresh-store schema remains V10; supported
migration sources remain V5 and V6.

Build 170 is the local three-feed-concurrency comparison build. It retains build
169's two-feed save batches and cooperative episode-insertion yields, changing
only the number of simultaneous feed fetches from two to three. Fresh-store
schema remains V10; supported migration sources remain V5 and V6.

Build 170.1 (device-test label “170A”) limits each OPML subscription's immediate
catalog insertion to its newest 10 episodes. Later ordinary refreshes add older
history as dismissed backlog, using the newest-date high-water mark established
during import so old episodes do not enter the Inbox or auto-download path. It
retains build 170's three-feed fetch concurrency, two-feed save batches, and
cooperative insertion yields. Fresh-store schema remains V10; supported
migration sources remain V5 and V6.

Build 171 is the direct-device and TestFlight upgrade verification build. It bounds
each VoiceOver migration-progress announcement wait at eight seconds, preventing
a missing UIKit completion callback from holding the ready UI indefinitely, and
renames Step 2 to “Upgrading your library database.” Its final TestFlight
candidate also publishes the selected playback speed as the Now Playing default
playback rate while retaining zero as the current rate when paused, allowing
single-button Bluetooth accessories to distinguish paused and playing states
above 1x. This supersedes the locally installed 171.1 verification label and
adds no timer, polling, or Now Playing update. Fresh-store schema remains V10;
supported migration sources remain V5 and V6.

Build 172 is the direct-device accelerated-playback heat verification build. It
keeps periodic playback housekeeping near one callback per wall-clock second at
all playback rates and reduces steady-state Now Playing elapsed-time corrections
from every five to every fifteen wall-clock seconds. Play, pause, seek, rate
changes, episode changes, and background persistence remain immediate. Fresh-store
schema remains V10; supported migration sources remain V5 and V6.

Build 173 is the development-only compact CloudKit projection feasibility build.
It returns both V10 application stores to local-only operation and mirrors a
separate relationship-free subscription projection, preventing the 232,921-row
episode catalog from blocking 662 subscription parents. Production CloudKit is
still disabled and undeployed. Fresh-store schema remains V10; supported
migration sources remain V5 and V6.

Build 174 is the development-only end-to-end compact CloudKit synchronization
build. It extends build 173's relationship-free projection to subscriptions,
meaningful episode playback state, queue order, shared settings, bookmarks,
listening history, and nested folder membership while keeping refetchable episode
catalogs, downloaded audio, caches, entitlement state, and other device-owned data
local. It also separates device-only clearing from an explicitly confirmed synced-
library deletion. Production CloudKit remains disabled and undeployed. Fresh-store
schema remains V10; supported migration sources remain V5 and V6.

## Builds that reached distribution

The build lists are exact. A missing number in a range was not present in App
Store Connect. `Drift Vn` is the legacy Flutter SQLite schema. `SwiftData Vn`
is the schema used by the current SwiftUI application.

| Builds | Channel | Fresh-store schema |
|---|---|---|
| 1-11 | TestFlight | Drift V5 |
| 12-17, 19, 21-49, 51 | TestFlight | Drift V6 |
| 52-53 | TestFlight | Drift V7 |
| 54-71 | TestFlight | Drift V8 |
| 72-80 | TestFlight | Drift V9 |
| 81-82 | TestFlight | Drift V10 |
| 83-84 | TestFlight | Drift V11 |
| 85, 90, 92-107 | TestFlight | Drift V12 |
| 108 | TestFlight | Drift V13 |
| 109 | TestFlight | Drift V14 |
| 110-112 | TestFlight | Drift V15 |
| 115-128, 131-137, 139 | TestFlight | SwiftData V3 |
| 140, 142-150 | TestFlight | SwiftData V4 |
| 151-154, 156-157 | TestFlight | SwiftData V5 |
| 155 | TestFlight and App Store | SwiftData V5 |
| 159-161 | TestFlight | SwiftData V6 |

The Flutter-to-SwiftUI handoff deliberately reused the bundle identifier. The
first uploaded SwiftUI build was 115. Its one-time crossover imports only
subscriptions from the legacy Drift database into a new SwiftData store. The
current V10 migration does not directly open a Drift store.

## Schema boundary evidence

The Flutter schema changes are frozen in the history of
`lib/data/db/app_database.dart`, now archived at
`archive/flutter/lib/data/db/app_database.dart`:

| Schema | First source commit | First uploaded build |
|---|---|---|
| Drift V5 | `3f78a67` | 1 |
| Drift V6 | `70602b7` | 12 |
| Drift V7 | `72d2e53` | 52 |
| Drift V8 | `a2bf65c` | 54 |
| Drift V9 | `3ac3b11` | 72 |
| Drift V10 | `0df8fb8` | 81 |
| Drift V11 | `730de10` | 83 |
| Drift V12 | `c673050` | 85 |
| Drift V13 | `cd515a7` | 108 |
| Drift V14 | `8dac69a` | 109 |
| Drift V15 | `a3ab093` | 110 |

Flutter V16 was committed after build 112 uploaded. No Flutter V16 artifact is
present in App Store Connect.

The shipped SwiftData code at the upload boundaries is direct evidence:

| Schema | First source commit | Uploaded builds |
|---|---|---|
| V3 | `170f195` | 115-139 |
| V4 | `a77b540` | 140-150 |
| V5 | `f383b0b` | 151-157 |
| V6 | `f232a7a` | 159-161 |

The ranges in this boundary table include unused build numbers for readability;
the exact uploaded numbers are in the distribution table above.

## Stores live in the wild

Only two SwiftData populations determine the current shipping migration floor:

1. Public App Store version 1.0.0 is build 155. Its shipped
   `StoreMigration.openOrMigrate` creates `EarshotSchemaV5`, and a fresh store
   records `NSStoreModelVersionIdentifiers = ["5.0.0"]`.
2. The last distributed TestFlight baseline is build 161. Its shipped code
   creates `EarshotSchemaV6`, includes the lightweight V5-to-V6 stage, and a
   fresh or upgraded store records `NSStoreModelVersionIdentifiers = ["6.0.0"]`.

Therefore the supported SwiftData migration floor is V5. V1-V4 are historical
TestFlight schemas and may use explicit recovery rather than a current migration
route. V5 is production data and must never be classified as pre-release or be
offered reset as its only path forward.

## Required release procedure

Before changing a migration floor:

1. Query App Store Connect for the public version's attached build and the
   latest TestFlight builds.
2. Inspect the shipped source at each identified build, including the schema
   passed to `ModelContainer` for a fresh store.
3. Migrate preserved fixtures from every live schema population and assert a
   save plus reopen succeeds.
4. Record any new distribution/schema boundary in this file in the same pull
   request that changes the build number or schema.
