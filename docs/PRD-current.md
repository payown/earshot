# Earshot: current product requirements

**Status:** Current implementation and proposed backlog, November 18, 2026. **Owner:** Michael Babcock. This document describes the SwiftUI iPhone, iPad, and Apple Watch product and separates shipped behavior from future requests. It does not commit any proposed feature to version 1.3.

The [May 17 original PRD](PRD.md) remains the historical design record. The [Personal Audio PRD](personal-audio-prd.md) retains its detailed scope and deferrals. This document is the current product overview; source code, release receipts, and live Start Testing records govern whether a particular change is implemented or accepted.

## Product and current architecture

Earshot is an accessible podcast player built for VoiceOver users and other listeners who want control over their library, queue, playback, and privacy. The present app uses native SwiftUI and SwiftData on Apple platforms, with a private CloudKit projection for supported sync state. It offers Earshot Plus through Apple in-app purchase. It does not ship the Flutter/Dart/Android shared codebase, Supabase account system, or default-on telemetry described in the original PRD (§§4, 6, 9–10). Android and a web companion are **proposals**, not current platforms or 1.3 requirements. Privacy claims must match the actual Privacy settings and App Store disclosures.

## Current capabilities and acceptance

| Area | Current status and source | Acceptance or remaining check |
| --- | --- | --- |
| Podcast library, Inbox, Queue, Downloads, folders, playback and configurable Quick Actions | Implemented in SwiftUI/SwiftData; original PRD §5.1–5.5. An episode-list or Queue double tap opens details; configured actions are in the VoiceOver Actions rotor. | Preserve downloaded files, explicit Inbox dismissal, playback position and Queue intent across sync. Public build 327 folder navigation, folder removal, multi-select and offline guide checks were reported passed by Chad and Michael, within that scope. |
| Private sync and Watch | Private CloudKit projection and Watch app exist, later additions to original PRD §§4, 15. | Cross-device Inbox/catalog equivalence and prompt paired Watch Queue convergence remain open. Do not re-enable immediate Watch queue snapshots while the build 312 crash cause is unproven. Four scoped build 326 Watch playback/UI tests passed; they are not universal sync acceptance. |
| Search and transcripts | `SearchView` separates local Library podcast/episode/bookmark results from Add Podcast directory search. Native transcript fetch, parse, view and export paths are implemented; original PRD §§5.6–5.7. | Original Search Everywhere, all-transcript search, and generated transcript design are not equivalent to these paths. Verify each proposed expansion separately. |
| Personal Audio | Local file import, playback and chapter handling implemented in phases documented by the [Personal Audio PRD](personal-audio-prd.md); original PRD §5.8. | Mixed Queue, folders, Share Sheet/direct open, URL import and CloudKit sync remain deferred. Personal audio is a separate model, not a synthetic podcast. |
| Listening stats | `StatsScreen`, `StatsPeriod`, `StatsRepository` and `StatsTests` implement weekly/monthly/yearly/all-time listening totals, speed savings, per-podcast breakdown, opt-in streaks and CSV; original PRD §5.9. | A year-in-review product is unverified. The UI shows speed savings; a separate silence-savings statistic is not established. Player discarded-frame accounting warrants investigation before a new stats requirement. |
| Onboarding and Help | Accessible onboarding and Help exist; original PRD §6 has obsolete telemetry toggles. | Chad passed the offline Inbox/Queue/Downloads guide on build 327. Fresh-install onboarding remains unverified; test with disposable data, never by deleting a real library. |

Selected feedback requests already represented in code remain distinct from
full physical acceptance:

| Request and Start Testing ID | Implementation and acceptance |
| --- | --- |
| Played/Unplayed terminology `9ef14a6a-17b7-4239-b5dd-3fa7b72a5dc2` and older-episode pagination `7ee3a6c1-69b4-4b60-9eac-bbb9ba12e706` | Implemented and merged; Michael accepted the tested wording, older loading, sorting and focus on a long show. Do not infer every screen or sort direction was tested. |
| Partially Played podcast filter `21cdd796-d1ba-469c-a630-fb9d9f27d1e9` | Implemented in the later integration. Michael approved its unfinished-with-position wording; broad physical sync and focus acceptance is separate. |
| Selected-episode Mark as Unplayed discoverability `0974d59d-da27-4f37-8248-85a02177e2b4` | The action exists. The approved settings-label and Help clarification is in draft PR #1090, not in public build 327. The whole-podcast request below is separate. |
| Select all/invert episode selection `4bc62015-6d92-4f59-a1a1-07416880bd45` and per-podcast Skip outro `ac2b2e5d-c538-4471-9c85-0c2a5071726b` | Implemented in earlier merged work; reporter-specific physical acceptance remains unverified. |

## Version 1.3 testing candidate

This is a **testing goal**, not an App Store release promise. Include only reviewed, regression-tested changes from the single candidate work list on draft PR #1091; that release checklist is branch-specific until integrated. Priorities are cross-device Inbox/catalog/Played state, iPad selection, Watch reliability, data safety and accessibility. An internal candidate must identify its exact source, signed artifact, CI and local results, skips, release notes, and physical checks. Public TestFlight and App Store release need separate decisions. Existing build 327 is a distinct signed baseline; later main changes are not automatically in it.

As checked on November 18, internal TestFlight 1.3.0 (328) is available from source `0faa9396` and includes the reviewed sync/privacy/Quick Actions candidate changes. The separate 1.3.0 (329) candidate at `dd73a7f0` adds the replay correction and has a signed IPA and passing exact-head CI, but **has not been uploaded or distributed**; its internal upload awaits authorization. Neither candidate makes the unmerged PRs part of main. Branch-specific candidate checklists and build receipts, rather than this dated snapshot, govern later availability and acceptance.

## Proposed feature requests, outside the committed 1.3 scope

These requests are carried forward for product decisions. “Proposed” means no delivery date, approved UI semantics or release commitment. Current Start Testing status and reporter intent should be checked before implementation.

| Request and traceability | Status and bounded acceptance question |
| --- | --- |
| Search/select multiple Library podcasts for folders — Start Testing `4564249b-d619-4ff7-a1ab-7538ddc8cdad`; original §5.1/§5.7 | Proposed. Keep stable selected IDs across query and scope changes, accessible selection state and long-list performance. |
| Configurable feed refresh cadence — `6137e2f5-7e96-495f-86dc-47deccb2a82a`; original §5.1 | Proposed. Explain that iOS controls background wake timing; a chosen interval cannot guarantee a fetch. |
| Explicit, cancellable Load All publisher history — `b7b8ff33-e5e0-453e-9e58-f6e99c455e40`; original §5.1 | Proposed. Bound pages/memory, deduplicate, resume and detect end of feed without automatic download or Inbox/Queue routing changes. |
| Whole-podcast Mark All as Unplayed — `ce334862-1fbb-42be-82f1-2afb0c5f7e0b`; original §5.4 | Proposed. Separate from the implemented selected-episode action. Specify scope and confirmation while preserving positions, downloads and explicit dismissal. |
| Custom intro/outro seconds — `50bd8bb4-1328-4deb-862a-cbf45666f143`; original §5.5 | Proposed. Validate input, persistence, episode boundaries and accessibility before UI changes. Per-podcast Skip outro already exists; its physical acceptance is a separate matter. |
| Optional no-automatic-age-limit listening history — listener request relayed by Michael on November 18 (no verified Start Testing ID); original §5.9 | Proposed. The current picker offers 30/60/90/180/365 days and defaults to 90. A nonpositive internal value skips automatic age cleanup, but no such option is offered in the current UI. Preserve existing explicit and synced choices; distinguish historical implicit 90 from explicit 90 before changing a default. Unfollow and remote unsubscribe separately remove linked sessions, so an age-limit option alone would not provide a permanent archive or recover previously purged history. Validate privacy, large Stats/CSV histories and older-client sync compatibility. |
| Find when a particular episode was heard — listener request relayed by Michael on November 18 (no verified Start Testing ID); original §5.9 | Proposed separately from retention. Current Stats aggregates by period and podcast, and CSV includes episode/date fields; no in-app dated per-episode history browser was verified. Define lookup, repeated listens, VoiceOver order and bounded large-history loading before implementation. |
| Personal Audio mixed Queue, folders, Share Sheet/direct open, URL import and CloudKit sync — [Personal Audio PRD](personal-audio-prd.md) final decisions | Deliberately deferred until cross-store identity, ordering, migration, privacy and data lifecycle are proven. |
| Year-in-review, separate silence-savings statistic, generated paid transcripts, Search Everywhere/all-transcript search, auto-watched Imports folder, timestamp universal links and web fallback — original §§5.6–5.9, 5.11, 15 | Proposed or unverified, with separate product/technical decisions. Generated transcripts require provider, privacy, cost and entitlement decisions. `EpisodeShareItems` currently emits an audio URL; do not claim the universal-link design shipped. |
| gpodder sync, Android, web companion — original §§4, 15, 18 | Deferred proposals. No implied account or sync architecture change. |
| Live podcasts, social features, audiobooks, AI summaries, smart playlists, Wear OS, family accounts, competitor-specific migration, custom themes, plugins and non-AirPlay casting — original §14 | Historical out-of-scope ideas, not approved 1.3 requirements. Reassess each only if a current request gives it a concrete need and acceptance scope. |
| Video podcasts — Start Testing `b4b13eb2-2e24-4146-8880-c3217fe35023` | Intentionally deferred; neither fixed nor a 1.3 completion gate. |

The request to “move the feature request into the new PRD” did not identify a single additional request beyond the known backlog. The verified requests above are carried forward without closing or moving their external tracker records. Add a newly identified request by its exact source and ID rather than guessing its scope.

## Historical decisions to retain, not silently implement

The original PRD records a Flutter/Dart Android plan, Supabase accounts, default-on crash/analytics toggles, a free/no-IAP launch model, and synthetic-podcast local imports. Current implementation supersedes each of those assumptions. The original PRD also contains accessibility, privacy and product principles still relevant, but its old platform matrix, onboarding copy and feature checkboxes cannot be read as a live release checklist. Do not alter persisted models or privacy settings to make old prose appear true.
