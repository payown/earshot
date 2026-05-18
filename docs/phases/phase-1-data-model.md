# Phase 1: Core data model, RSS parsing, subscription management

**Goal:** Earshot can subscribe to a podcast via RSS URL, parse the feed, store podcasts and episodes locally, and display them in a list.

**Estimated duration:** 2-3 weeks

## Tasks

### 1. Database schema (drift)
- [ ] Define tables: `podcasts`, `episodes`, `subscriptions`, `quick_action_configs`
- [ ] Define enums: `episode_status` (new, in_queue, played, expired), `download_status`
- [ ] Generate code with `dart run build_runner build`

### 2. RSS parsing
- [ ] Add `webfeed` or implement custom RSS parser
- [ ] Parse standard RSS 2.0 + iTunes namespace + Podcasting 2.0 tags (chapters, transcripts)
- [ ] Handle malformed feeds gracefully

### 3. Subscription feature module
- [ ] `lib/features/subscriptions/data/` — repository, models
- [ ] `lib/features/subscriptions/domain/` — entities, subscribe use case
- [ ] `lib/features/subscriptions/presentation/` — list screen, detail screen, add-by-URL screen

### 4. UI: Add podcast by RSS URL
- [ ] Input field with paste support
- [ ] Validation, loading state, error state
- [ ] Full semantic labels, Dynamic Type, dark mode

### 5. UI: Subscriptions list
- [ ] List of subscribed podcasts
- [ ] Tap to open detail
- [ ] Pull-to-refresh updates feeds
- [ ] Empty state with "Add your first podcast" button

### 6. UI: Podcast detail
- [ ] Header with title, artwork, description
- [ ] Episode list (most recent first)
- [ ] Subscribe/unsubscribe button

### 7. Feed refresh logic
- [ ] Manual refresh
- [ ] Background fetch every ~6 hours
- [ ] Deduplication by GUID

### 8. Tests
- [ ] Unit tests for RSS parser
- [ ] Repository tests with in-memory drift DB
- [ ] Widget tests for screens (semantic labels, list rendering)

## Definition of done

- User can paste an RSS URL and subscribe
- Subscription persists across app restarts
- Episode list shows for each subscribed podcast
- All screens fully accessible (VoiceOver and TalkBack tested)
- Unit and widget tests pass

## End of phase

When Phase 1 is done, ask Claude Code to write Phase 2's detailed doc. Use this prompt:

```
Phase 1 is complete. Walk me through the Definition of Done and confirm. Capture learnings: what we built, what we learned about the data model and RSS parsing, anything we deferred. Update CHANGELOG.md. Then write docs/phases/phase-2-playback-engine.md following .claude/rules/phase-progression.md. Don't start Phase 2 work; let me confirm the plan first.
```

## Claude Code prompts

**Prompt 1: design the schema**
```
Read docs/PRD.md sections 5.1 and 5.2. Design the drift database schema for podcasts, episodes, and subscriptions. Account for the v1 features and leave room for v1.1 sync without committing to it now. Create the .drift files in lib/data/db/ and the generated code via build_runner.
```

**Prompt 2: RSS parser**
```
Implement an RSS parser in lib/data/rss/ that handles standard RSS 2.0, iTunes namespace, and Podcasting 2.0 tags (chapters, transcripts, persons). Use the webfeed package as a starting point but extend for Podcasting 2.0. Write unit tests with sample feeds in test/data/rss/fixtures/.
```

**Prompt 3: subscription feature**
```
Build the subscriptions feature in lib/features/subscriptions/ following the three-layer pattern in CLAUDE.md. Include repository, Riverpod providers, add-by-URL screen, subscriptions list, and podcast detail screen. Every interactive element needs full Semantics labels. Test with VoiceOver before considering done.
```
