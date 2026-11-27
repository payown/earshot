# Listening Places two-way readiness — November 27, 2026

This follows the [write-only 1.2.0 plan](listening-places-1.2.0-plan.md).
Signed Earshot 1.3.1 (335) still writes only its own device file. This
document records the verified gates for importing places from another app;
it is not a claim that two-way sync or subscriptions are available in 335.

## Source and compatibility

- Earshot's public episode ID trims the GUID (or enclosure URL) and hashes it;
  the existing two device fixtures and six ID vectors match QUILL's merged
  interop tests. QUILL PR #2095 merged on November 27. A disposable clone pinned
  at `64651e5884b779b7cf75e3c5cc4125b77a983e82` passed 27 interop and 21
  conformance/subscription tests. This is local format evidence, not a real
  provider, Windows, or NVDA result. Its current code and
  fixtures are the useful comparison; its `listening-places-spec.md` prose is
  behind the implementation on subscription support, GUID trimming, and plain
  feed URLs in opt-in subscription records.
- `git diff c11dda93..35f90ead -- Earshot/Features/ListeningPlaces` is empty:
  the signed 335 writer itself has no later change in that feature directory.
- The standalone QUILL Cast release host's Latest currently resolves to
  `v1.0.0`; that label does not prove an installed desktop build includes the
  subscription controls from the pinned source. Before S1–S15, confirm the
  desktop app exposes both its plain-file Listening Places control and “Also
  share the podcasts I follow” in Carry My Place Between Machines. Record its
  exact source/build so a missing control is not mistaken for an Earshot bug.
- One device owns one JSON file. An Earshot reader must not write, rename, or
  delete another device's file. A read failure or unfamiliar row cannot make
  a valid episode row disappear from the same or another file. Before any
  future apply, compare a safe filename ID with the file's self-reported
  device ID; neither that ID nor the display label authenticates the writer.
- The external file may reveal titles when labels are enabled. Opt-in
  subscription rows also contain plain feed URLs. This is distinct from
  Earshot's private iCloud sync and needs explicit local controls and copy.

## Data-safety gates before applying remote state

1. **Real event time.** The current writer stamps changed episode state when
   it exports (`ListeningPlacesSnapshotLoader.addRecord`), which can happen
   after a newer desktop event. `Episode` has no durable general position or
   reset time when iCloud is off. Legacy unknown-time state must not gain an
   invented timestamp. Any new clock needs crash-between-saves and relaunch
   tests before an import is enabled. A device-local sidecar prototype did
   survive relaunch and reject a single missed update, but a disposable
   A → B → A test showed its state signature could match an old timestamp
   again after two missed updates. The prototype was removed from the
   candidate branch; its failing diagnostic is retained locally. A clock
   needs enforced coverage of every producer or an atomic persisted revision,
   not just a signature comparison.
   The current write audit includes explicit and throttled PlayerService
   checkpoint saves, seek and handoff application, natural completion,
   Quick Actions, Inbox and podcast bulk Played/Unplayed, Queue mutations,
   identity repair, and CloudProjection import. `Episode.playedAt` records
   only a played transition; it is not a position/reset clock. Capturing a
   timestamp at one UI entry point would leave other saved changes untimed.
2. **Latest-event position.** A deliberate newer backward seek must win. The
   current iCloud projection normally takes the maximum eligible position,
   so passing a desktop record into it unchanged would not implement this
   rule. Played, Unplayed, ties, tombstones, iCloud ordering, loaded-player
   deferral, and republishing need one reviewed merge policy.
3. **Preserving the library.** Local `SubscriptionDeletionRepository.unsubscribe`
   deletes sessions and cascades podcast/episode rows. It cannot implement a
   remote subscription-only unfollow that retains episodes, downloads and
   history. Remote follow/unfollow, folder parent/extra-membership round trips,
   URL aliases, and per-device private-feed choices need a separate tested
   preservation path. Earshot now has nested folders, so the earlier flat-folder
   description is stale; folder `parent` and extra memberships still require
   round-trip proof. QUILL's pinned
   `test_what_cast_cannot_hold_is_carried_back_untouched` preserves a second
   Earshot folder membership, `sortOrder`, and Earshot `app_private` metadata
   on re-export; Earshot's round trip must preserve them too. No remote
   subscription mutation is enabled by a parser.
   Marking a Podcast `catalogOnly` can preserve its rows locally, but the
   current CloudProjection import can re-promote an active iCloud subscription,
   while its local publication can treat the absent follow as an iCloud
   unfollow. A Listening Places remote-unfollow path must suppress both effects
   with a durable device-local source/ownership rule before it can be called.
4. **Privacy.** A device-local "keep here" choice must suppress that show's
   subscription, folders, episode places and incoming changes without emitting
   an unfollow tombstone. Private feed URLs and authentication must never enter
   the plain shared file. Existing written records need careful treatment so
   a policy change does not leave or recreate private rows.
   The current writer can retain an older hashed place even after an episode
   is no longer in the local catalog. Excluding only currently known private
   feeds would therefore not prove that all previously shared private places
   were purged; a reviewed rewrite/purge rule is required before claiming S8/S15.
5. **Input and scale.** Before applying anything, cap coordinated reads, parse
   valid rows independently of malformed/unknown ones, normalize time to UTC,
   validate IDs, clamp positions, ignore stale devices, and index a large local
   episode catalog once off the interaction path. The current 1,000-record
   writer cap cannot silently let subscription rows evict episode places.

Conservative interim choices: read only at launch or an explicit request, not
during playback; leave a loaded episode untouched, including one that is paused;
leave unknown-time legacy state unchanged instead of stamping it at import or
export time; and leave remote subscription/unfollow rows unapplied until the
preserving path is proven. None of these choices may be described as complete
two-way sync. Personal Audio import exists in Earshot, but the current places
writer does not exchange local-file IDs; adding that identity is separate work.

The isolated foundation branch adds a bounded, read-only peer-file transport,
tolerant episode/tombstone parser, conservative subscription identity helper,
and a pure per-episode merge planner. The planner's initial seven focused tests cover
newer backward seeks, older/newer resets, loaded-episode deferral, remote ties,
unknown legacy time, guarded future clocks, and conflicting same-device rows.
An eighth fail-before/pass-after regression keeps a repeated, already-applied
peer event from triggering another application. The final eight-test planner
run passed on iOS 26.5 (`EarshotLPIdempotenceAfter20261127.xcresult`); its
pre-fix run failed exactly that repeat-import assertion.
It does not invoke the reader from the app or apply remote state. Its combined
iOS 26.5 focused run on November 27 passed 24 tests with no failures or skips
on final code (`EarshotLPFinalFocused20261127.xcresult` in local verification
artifacts).
That result covers synthetic files and fixture agreement, not a 336 release.

## Verification before an internal two-way candidate

Use disposable feeds, stores, folder fixtures and media only. Prove a delayed
phone export (T1) cannot beat a newer desktop place (T2); backward seeks and
newer resets win, older tombstones lose, and legacy unknown-time entries are
preserved. Test a loaded playing and loaded paused episode, unknown episodes
that arrive on a later feed refresh, malformed files/rows, wrong clocks,
duplicate device IDs, provider placeholders, file ownership, and 1,000 places
against a large library. For subscriptions, test opt-in/out, stale unfollow
after resubscribe, private feeds, device-only switching without a tombstone,
folder nesting and multiple memberships, speed only for the show, and remote
unfollow without deleting downloads/history. Run exact-source full regression
and physical Dropbox/iCloud Drive/OneDrive and VoiceOver/NVDA checks separately.

The proposed new status and spoken control wording requires the repository's
accessibility-semantics sign-off before it is presented to users. Until these
gates pass, a bounded read-only parser or file reader is infrastructure, not
an enabled receiver or a reason to cut a Listening Places build.
