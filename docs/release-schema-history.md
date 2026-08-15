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

Build 175 is the development-only large-library responsiveness follow-up. It
keeps build 174's compact CloudKit projection unchanged and replaces the global
Inbox's live SwiftData observation with explicit Inbox- and queue-change
refreshes, preventing unrelated catalog-rebuild saves from repeatedly
materializing the Inbox on the main actor. Production CloudKit remains disabled
and undeployed. Fresh-store schema remains V10; supported migration sources
remain V5 and V6.

Build 176 is the development-only clean-second-device bootstrap follow-up. A
relationship-free synced subscription now seeds a bounded ten-episode local
catalog on its first feed refresh while preserving the transferred high-water
mark, so historical rows stay dismissed and only later publications count as
new. Production CloudKit remains disabled and undeployed. Fresh-store schema
remains V10; supported migration sources remain V5 and V6.

Build 177 is the development-only large-library feed-rebuild follow-up. It
overlaps at most three network fetch-and-parse operations while retaining one
serialized SwiftData writer, input-ordered results, batched saves, and prompt
background-task cancellation. Production CloudKit remains disabled and
undeployed. Fresh-store schema remains V10; supported migration sources remain
V5 and V6.

Build 178 is the development-only feed-executor correction. Device profiling
showed build 177's `FeedRefreshActor` had been constructed on the main actor,
pinning SwiftData relationship work to the UI thread. Every production call site
now creates that model actor on a detached utility executor. Build 177 is
superseded for testing. Production CloudKit remains disabled and undeployed.
Fresh-store schema remains V10; supported migration sources remain V5 and V6.

Build 179 is the development-only bounded automatic-refresh correction. Device
profiling showed build 178 moved feed persistence off the main actor, but
faulting a real 45,436-episode inverse relationship still caused repeated UI
stalls. Established subscriptions now preserve all stored history while
ingesting at most the newest ten genuinely-new episodes per automatic refresh;
older feed-catalog rows remain refetchable rather than local or CloudKit state.
Build 178 is superseded for testing. Production CloudKit remains disabled and
undeployed. Fresh-store schema remains V10; supported migration sources remain
V5 and V6.

Build 180 is the development-only targeted duplicate-repair correction. A
build-179 device trace proved its pre-refresh identity repair still fetched all
45,436 stored episodes for one podcast before reaching the new history bound.
Refresh now repairs only GUIDs eligible to participate in that refresh. Build
179 is superseded for testing. Production CloudKit remains disabled and
undeployed. Fresh-store schema remains V10; supported migration sources remain
V5 and V6.

Build 181 is the development-only bounded CloudKit resolution correction. A
build-180 device trace reduced refresh stalls to one 780-millisecond hang and
identified it in queue reconciliation: resolving one projection faulted and
sorted an entire podcast episode relationship. CloudKit reconciliation now
fetches only the requested podcast/GUID pairs. Build 180 is superseded for
testing. Production CloudKit remains disabled and undeployed. Fresh-store schema
remains V10; supported migration sources remain V5 and V6.

Build 182 is the development-only restartability follow-up. Initial compact
subscription projection saves every 50 changed rows and resumes by canonical
feed URL after interruption without duplicating already durable subscriptions.
Build 181 is superseded for testing. Production CloudKit remains disabled and
undeployed. Fresh-store schema remains V10; supported migration sources remain
V5 and V6.

Build 183 is the development-only two-device safety follow-up. A completed
background download whose episode was removed locally or by remote sync now
deletes its unowned audio file without touching a deleted SwiftData object.
Destructive local-data actions await URLSession invalidation and a bounded
URLCache SQLite drain before moving or deleting the artwork-cache directory.
Build 182 is superseded for testing. Production CloudKit remains disabled and
undeployed. Fresh-store schema remains V10; supported migration sources remain
V5 and V6.

Build 184 is the development-only CloudKit availability follow-up. A foreground
transition retries projection activation after signed-out or temporarily
unavailable account states without polling. Activation is serialized through
one cancellable task, and reset or account replacement cancels and awaits that
task before touching persistent files. Build 183 is superseded for testing.
Production CloudKit remains disabled and undeployed. Fresh-store schema remains
V10; supported migration sources remain V5 and V6.

Build 185 is the development-only two-device queue correction. A physical
build-184 test showed CloudKit delivered Mac queue records to the iPhone compact
projection, but the visible queue could not materialize episodes absent from the
iPhone's independently bounded catalog. Queue contributions now include optional
episode metadata so reconciliation can create one dismissed local episode shell.
Concurrent feed-refresh results are also re-resolved by their captured requested
feed URL before any SwiftData write, preventing a stale model/index association
from attaching one feed's episodes to another podcast. Build 184 is superseded
for testing. Production CloudKit remains disabled and undeployed. Fresh-store
schema remains V10; supported migration sources remain V5 and V6.

Build 186 is the development-only targeted queue-data repair. Read-only
comparison found both compact stores converged on nine queue keys while the Mac
application store retained one additional unprojectable AppleInsider queue row
whose episode had lost its podcast relationship. The repair moves that exact
manifest entry to the unique matching AppleInsider catalog row only when GUID,
title, audio URL, and feed identity all match, then removes the single approved
orphan episode. Other unprojectable queue rows are logged and left untouched;
there is no general orphan recovery. Production CloudKit remains disabled and
undeployed. Fresh-store schema remains V10; supported migration sources remain
V5 and V6.

Build 186 also brackets development-only initial compact-projection seeding with
stable start, completion, and failure log markers. A run identifier joins each
pair; completion records monotonic duration and counts for all seven projection
entities. The instrumentation is gated by
`EarshotDevelopmentCloudKitEnabled`, so the ordinary Release configuration does
not create, seed, or open the projection store. Version 1.1.0 is approved as a
migration-only TestFlight release with that Release gate remaining `NO`.

Builds 187 through 199 are development-only compact-CloudKit verification and
correction builds. They retain fresh-store schema V10 and the supported V5/V6
migration floor. Their measured device work covers feed ingestion, bounded
refresh and OPML import, honest iCloud status, queue and playback reconciliation,
concurrent remote unfollow, and safe Now Playing dismissal. Build 199 passed the
final two-device remote-unfollow presentation test and is recorded in
`docs/testflight/build-199-device-test-plan.md`. None of these builds deployed a
production CloudKit schema.

Build 200 is the first production-release candidate that enables the compact
private CloudKit projection in the Release configuration. Debug remains
local-only; the explicit CloudKit Development configuration remains available
for pre-production testing. The signing profile selects the CloudKit environment.
Both V10 application stores remain local-only and only the relationship-free
seven-entity projection is eligible for private CloudKit mirroring. Fresh-store
schema remains V10; supported migration sources remain V5 and V6. Production
schema deployment and TestFlight upload remain separate, explicitly approved
release actions.

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
