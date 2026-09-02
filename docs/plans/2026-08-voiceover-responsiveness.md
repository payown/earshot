# VoiceOver responsiveness improvement plan

Status: the first implementation was distributed in TestFlight build 251 on
2026-09-01, and Michael confirmed that build 251 is installed and in active use.
It includes the Library scalar fetch, podcast episode paging, bounded local
search, folder snapshot, background startup-maintenance, tab-badge, and compact
Cloud-projection work. This plan remains the source for uncompleted follow-ups;
build 251 does not claim that every phase below is finished.

The 2026-09-02 direct-device follow-up on
`codex/background-mainactor-work` moves three additional store-heavy paths away
from the interaction actor without changing accessibility semantics:

- global and folder-scoped Inbox membership queries now execute on private
  contexts and return persistent identifiers; main-context resolution yields in
  groups of 100, and stale reloads cannot publish over a newer scope;
- Listening Places restore, history scanning, normalization, and JSON encoding
  now execute on a private model actor in 256-row fetch batches; and
- launch-time queue expiration and Recently Expired cleanup now execute on a
  private context at utility quality of service.

This is deliberately not described as completion of Inbox paging. Search,
counts, focus recovery, and existing bulk actions still use the complete Inbox
scope to preserve build 251 behavior. A later paging change must also move those
full-scope operations into bounded repository batches before the first-page-only
contract in Phase 4 can be claimed.

The 2026-09-02 `codex/concurrency-snappy` follow-up tightens that work without
changing the Inbox interaction contract:

- Inbox snapshots, tab-badge counts, launch expiration, and stats retention use
  structured `@concurrent` entry points instead of continuation-wrapped GCD
  blocks, so task cancellation remains visible to the work;
- the global Inbox snapshot now excludes played legacy history in the store,
  matching the already-bounded badge and folder predicates before models are
  materialized; and
- interactive Stats aggregation and CSV generation/write run on private
  contexts, while confirmed history deletion runs off-main in durable 256-row
  batches. Generation checks prevent an older period/folder result from
  replacing a newer selection.

Physical-device use of that direct build then isolated a foreground-resume
latency trigger: VoiceOver speech on an already-presented Now Playing screen was
significantly slower only after the 15-minute feed-refresh throttle elapsed.
Foreground CloudKit retry and feed refresh had started in the same scene-active
turn in which iOS rebuilds the accessibility tree and restores VoiceOver focus.
The foreground maintenance request now runs at utility priority after a
structured, cancellable three-second grace period. Returning inactive or
background during that period cancels the request, while player state, speech,
focus, and audio-session behavior remain unchanged. The heavy refresh engine
remains on its private model actor; this change reserves the
interaction-critical resume window rather than moving AVPlayer or UI-owned
state away from the main actor.

Full Inbox paging is still intentionally open. It must preserve full-scope
search, Download all, Clear Inbox, selection, exact counts, and VoiceOver focus;
splitting that semantic change from the executor correction keeps both reviews
small and independently reversible.

The original build 250 Release-device trace remained blocked by the iOS 27/Xcode
26.6 device support mismatch. The missing metrics and the still-main-context
Inbox candidate fetch are preserved as open evidence/implementation boundaries
rather than being described as completed work.

## Objective

Keep VoiceOver navigation immediate and predictable as Earshot grows from an
ordinary library to the known stress cases: one podcast with 45,436 stored
episodes and a library exceeding 242,000 episodes.

This work is about responsiveness, not changing what Earshot says. Existing
accessible names, values, traits, hints, Actions rotor order, default activation,
focus restoration, and announcements remain byte-for-byte unchanged unless a
specific spoken change is separately approved.

The code audit is strong enough to identify the first work, but it is not a
substitute for Release-device evidence. Every phase starts and ends with the same
VoiceOver interaction captured on the same physical device.

## Code-backed findings, in priority order

### 1. Podcast episode lists fault and repeatedly process the full relationship

`EpisodeListView.sortedEpisodes` reads `podcast.episodes`, sorts the complete
inverse, then independently derives filtered, searched, and unplayed collections.
`body` reads those computed collections several times and renders the whole
result. The known 45,436-episode relationship has already produced refresh-time
stalls elsewhere in Earshot, so this is the clearest remaining screen-level risk.

### 2. Search subscribes to the entire local catalog in every scope

`SearchView` declares unbounded `@Query` collections for all followed podcasts,
episodes, and bookmarks. It filters those arrays in memory as the query changes.
The Add Podcast scope pays for the episode and bookmark collections even though
it never displays them. With 242,000 episodes this can make merely opening Search
expensive and makes typing fan out across the complete catalog.

### 3. Library rows can fault descriptions one row at a time

`SubscriptionsView.loadPodcasts` uses a partial fetch but does not include
`podcastDescription`. A row reads that property to construct visible and spoken
details. Rapid VoiceOver flicking can therefore turn into a sequence of main
context faults.

### 4. Folder views perform broad membership work during presentation

`FolderDetailScreen` calls repository-derived computed properties from `body`.
`FolderRepository.episodeMemberships(in:)` fetches every episode membership and
filters in memory, while podcast membership counts can rescan global membership
collections per row. These costs grow with the entire folder graph rather than
the opened folder.

### 5. Inbox presentation is bounded, but its reload is not

The Inbox already displays event-driven batches, but
`InboxRepository.inboxEpisodes()` fetches every matching candidate and
`AllInboxCandidates.reload()` performs that synchronous main-context work. A
large accumulated Inbox can therefore pause VoiceOver before the first bounded
batch appears.

### 6. Secondary full-history and parsing work remains on the main actor

- `StatsRepository` fetches and filters broad listening-session histories.
- `SpokenDescriptionCache` sanitizes HTML synchronously on a cold row-cache miss.
- `ShowNotesView` reparses the complete description from a computed property on
  each evaluation, even though paragraph rendering itself uses `LazyVStack`.

These are lower priority than the list and Search paths, but are measurable and
should not be left as permanent unbounded work.

## Performance and accessibility contract

Each implementation PR must satisfy all of the following:

1. No screen may fault `Podcast.episodes` to display or count a large episode
   list. Use podcast-scoped store predicates and bounded pages.
2. Initial screen work is proportional to the visible page, not total library
   history.
3. Paging is deliberate under VoiceOver. Loading more content never steals
   focus or inserts rows ahead of the focused element without an announcement.
4. Bulk actions still operate on their documented full scope even when the UI
   holds only one page. They use bounded store-side batches rather than the
   visible array.
5. Stable persistent identity remains the `ForEach` identity. No `id: \.self`,
   regenerated UUIDs, or root conditional swapping is introduced.
6. Background work returns Sendable scalar snapshots or persistent identifiers;
   SwiftData models never cross actor boundaries.
7. Existing speech and focus tests are golden tests. Any textual difference is a
   regression unless Michael explicitly approves it.
8. No schema migration, server, analytics, or accessibility-setting change is
   required for this project.

## Phase 0: establish a reproducible Release-device baseline

Add privacy-safe Points of Interest intervals and bounded scalar metadata only:

- `EpisodeListInitialPage`, `EpisodeListLoadMore`, and `EpisodeListSearch`
- `LocalSearchQuery`
- `LibrarySnapshotLoad`
- `FolderDetailSnapshot`
- the existing `InboxReload`, extended with candidate and returned counts
- `StatsAggregation`, `SpokenDescriptionPrepare`, and `ShowNotesParse`

Never log titles, feed URLs, GUIDs, descriptions, search text, or account data.

Capture SwiftUI and Time Profiler together on a signed Release build with
VoiceOver running. Record wall time, main-thread longest interval, peak memory,
and whether a right-flick produces immediate speech for:

1. Opening and flicking through the 45,436-episode podcast.
2. Switching All/Unheard, newest/oldest, and searching that podcast.
3. Opening Add Podcast Search and Library Search with the 242,000-episode store.
4. Typing and deleting a five-character search query.
5. Rapidly flicking through Library rows with Full podcast descriptions enabled.
6. Opening the largest folder and Inbox, then loading the next visible batch.
7. Opening Stats and unusually long show notes from a cold cache.

Keep the raw trace and a short metrics table under `docs/device-test-artifacts`.
The baseline is complete only when the exact reproduction and build SHA are
recorded.

## Phase 1: remove the low-risk Library row fault

PR 1 should include `podcastDescription` in the existing bounded Library partial
fetch, or return a lightweight row snapshot containing the same scalar. Do not
replace the current event-driven snapshot model.

Tests:

- Partial-fetch coverage proves every scalar read by a Library row is present.
- Existing exact `PodcastRowSpeech` label and value tests remain unchanged.
- A diagnostic test verifies rapid row speech does not fault an episode
  relationship.

Acceptance:

- No description-related SwiftData faults during a cold-cache Library flick.
- Identical row speech in Off, Brief, and Full modes.

## Phase 2: page podcast episode lists without weakening their features

Introduce an episode-list data source owned by the screen. It performs
podcast-scoped `FetchDescriptor<Episode>` requests with stable publication-date
and persistent-identity tie breaking. Load 100 rows initially and 100 per
explicit request. Keep only loaded model identifiers and compact row inputs in
view state.

Before implementation, add predicate capability tests for:

- podcast identity plus `playedAt == nil` for Unheard;
- newest and oldest publication ordering with deterministic ties;
- case-insensitive title and description search;
- fetch count for the whole matching scope.

If SwiftData cannot execute a search predicate reliably, stop and choose a
bounded background scan with cancellation and incremental pages. Do not silently
fall back to faulting `podcast.episodes`.

UI behavior:

- Preserve the current header, filter picker, search field, sort action, row
  speech, row actions, selection behavior, and focus restoration.
- Add one nonautomatic `Show 100 more episodes` boundary after the loaded page.
  Its label includes how many are loaded and, when cheaply known, how many match.
- Keep the existing remote older-episode control separate. Stored-page loading
  must be exhausted before the remote-history control is presented as the next
  source.
- Search, filter, and sort reset the local page and place focus on the results
  heading, never an arbitrary new row.
- Mark all played and multi-select batch actions use podcast-scoped repository
  batches; they are not limited to loaded rows unless the current UI explicitly
  says “selected.”

Tests:

- 45,436-row fixture loads only the first 100 models initially.
- Newest/oldest, All/Unheard, search, empty result, and load-more ordering.
- Duplicate publication dates remain stable across page boundaries.
- A row deleted or republished between pages cannot duplicate or crash.
- Exact existing speech, Actions rotor order, selection focus, and mark-played
  neighbor focus.

Acceptance:

- Opening the stress podcast does not enumerate its inverse relationship.
- Peak memory and initial latency remain approximately flat when the fixture is
  increased beyond 45,436 rows.
- VoiceOver right-flick remains responsive while a later page loads.

## Phase 3: isolate and bound Search by scope

Split local Library search from directory/Add Podcast search at the data-source
boundary. Add Podcast must instantiate no all-episode or all-bookmark query.

For Library search:

- Debounce the query as today and cancel superseded work.
- Query podcasts, episodes, and bookmarks independently with store predicates.
- Cap the initial result page per section and provide a stable Show more boundary.
- Build Sendable result identifiers/snapshots off-main, then resolve only the
  displayed rows on the main context.
- Preserve directory-result behavior, count announcement suppression, search
  focus, row speech, and every existing action.

Tests:

- Add Podcast scope proves episode and bookmark loaders are never created.
- A superseded query cannot publish late results or move focus.
- Section caps, Show more, empty/failure states, and exact count announcements.
- 242,000-row diagnostic proves first results do not materialize the catalog.

Acceptance:

- Opening Add Podcast Search has cost independent of local episode count.
- Typing remains responsive with VoiceOver and does not announce obsolete result
  counts.

## Phase 4: snapshot Folder and Inbox data outside `body`

Folder work:

- Replace computed repository fetches in `FolderDetailScreen.body` with one
  event-driven `FolderDetailSnapshot`.
- Use folder- or subtree-scoped membership predicates. Compute membership counts
  once into an identifier-keyed dictionary rather than once per row.
- Invalidate only on folder membership, folder deletion, episode-state, or
  subscription events relevant to the snapshot.

Inbox work:

- Return the first 100 matching identifiers from a background store actor.
- Resolve and display that page on the main context.
- Load later pages explicitly without moving VoiceOver focus.
- Clear Inbox, Add all, and folder-scoped bulk operations continue to process the
  complete eligible scope in bounded actor batches.
- Coalesce duplicate Inbox and Queue notifications arriving in the same run-loop
  turn so one durable mutation produces one reload.

Tests cover scoped fetches, notification coalescing, page boundaries, concurrent
deletion, bulk-action full scope, and existing focus/speech behavior.

## Phase 5: move secondary work off the VoiceOver path

1. Completed on `codex/concurrency-snappy`: interactive aggregation returns a
   Sendable scalar snapshot from a private context; CSV formatting and writing
   are off-main; retention and confirmed delete-all use bounded background
   batches. Remaining predicate refinement can be measured independently.
2. Precompute exact spoken-description strings for the next visible page off the
   main actor. Keep the current bounded cache and verify output against golden
   strings before switching callers.
3. Parse show-note paragraphs once in a cancellable task and render them with
   `LazyVStack`. Preserve one VoiceOver element per paragraph, link attributes,
   reading order, and the existing empty state.

These should be separate PRs so a text-output regression cannot hide inside a
Stats or layout refactor.

## Verification and rollout

Every PR runs:

- focused repository, paging, speech, focus, and Actions rotor tests;
- the full unit and UI suite with only the documented StoreKit exclusions;
- a clean optimized Release build under complete strict concurrency;
- the same physical-device trace and VoiceOver interaction from Phase 0.

For list/search PRs, also test with VoiceOver Read All, rapid manual flicking,
Explore by Touch, search dismissal, app background/foreground, and a refresh
that changes the visible collection. Verify Dynamic Type and Reduce Motion even
though semantics are unchanged.

Stop the rollout if any change causes repeated speech, focus jumps, missing
Actions rotor items, stale pages, a main-thread hang visible in the trace, or
memory that grows with total history instead of page size. TestFlight should
receive the phases incrementally, beginning with the low-risk Library fetch and
episode-list paging, rather than one app-wide performance rewrite.

## Recommended order and confidence

1. Instrument and capture the baseline.
2. Ship the Library scalar-fetch correction.
3. Implement episode-list paging.
4. Isolate and bound Search.
5. Snapshot Folder and Inbox data.
6. Move Stats, description preparation, and show-note parsing off-main.

Confidence is high that Phases 1 through 3 address the largest remaining
VoiceOver stalls because the causes are directly visible in code and match prior
large-relationship failures. Exact improvement percentages should not be
predicted until the Phase 0 Release-device traces exist.
