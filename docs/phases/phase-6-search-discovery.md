# Phase 6: Search, OPML, local audio import, podcast discovery

**Goal:** Users can search for podcasts via Apple Podcasts directory and Podcast Index, import/export OPML, search within the app, and import local audio files.

**Estimated duration:** 2-3 weeks (part-time)

## Prerequisites

- Phase 5 complete: stats and settings working
- iTunes Search API requires no API key
- Podcast Index API requires a free API key (sign up at podcastindex.org)

## Tasks

### 1. iTunes Search API (Apple Podcasts directory)
- [ ] `PodcastSearchService` in `lib/features/search/`
- [ ] GET `https://itunes.apple.com/search?term={query}&media=podcast&limit=20`
- [ ] Parse response: `results[]` with `trackName`, `artistName`, `artworkUrl100`, `feedUrl`
- [ ] Return list of `SearchResult` domain objects
- [ ] Debounce search input (300ms)

### 2. In-app search
- [ ] Search bar on Subscriptions tab activates context-aware search
- [ ] Search in subscriptions list → filters currently subscribed podcasts
- [ ] "Search Everywhere" button expands to Apple Podcasts + Podcast Index
- [ ] Tapping a directory result shows preview (title, author, description) with "Subscribe" button
- [ ] Accessible: search field label, clear button, result count announced

### 3. OPML import
- [ ] File picker (iOS: Files app, Android: SAF) to select `.opml` or `.xml` file
- [ ] Parse OPML: `<outline type="rss" xmlUrl="..." text="..."/>`
- [ ] Bulk subscribe: for each feed URL, call `PodcastRepository.subscribe`
- [ ] Show progress with count ("Subscribed 3 of 7") announced via semantics
- [ ] Handle duplicates gracefully (already-subscribed error silently skipped)
- [ ] Import button in Settings

### 4. OPML export
- [ ] Generate OPML XML from current subscriptions
- [ ] Share via system share sheet as `earshot-subscriptions.opml`
- [ ] Export button in Settings

### 5. Podcast Index integration (optional, best-effort)
- [ ] Add Podcast Index API key to app config (user-supplied or app default)
- [ ] `GET https://api.podcastindex.org/api/1.0/search/byterm?q={query}`
- [ ] Merge results with iTunes search (deduplicate by feed URL)
- [ ] Podcasting 2.0 metadata from Podcast Index: chapters, transcripts flags

### 6. Local audio import
- [ ] iOS: handle "Open In" / share extension for audio files (.mp3, .m4a, .aac, .wav)
- [ ] Copy file to app documents, create a synthetic "Local Audio" podcast entry
- [ ] `Library` section in Downloads tab (or new tab) showing imported audio
- [ ] Imported audio gets same Quick Actions, queue, stats, bookmarks as podcast episodes
- [ ] Android: system file picker via `file_picker` package

### 7. Tests
- [ ] Unit tests: OPML parser (valid, malformed, empty)
- [ ] Unit tests: iTunes search response parsing
- [ ] Widget tests: search screen states (empty, loading, results, error)
- [ ] Widget tests: OPML import progress accessible

## Definition of done

- Search field on Subscriptions tab filters subscriptions live
- "Search Everywhere" returns podcast results from Apple Podcasts directory
- Tapping a result lets user subscribe
- OPML import subscribes to all feeds in the file
- OPML export produces a valid file that other apps can import
- All search results and actions accessible to screen readers
- Tests pass

## Commands to use during this phase

```bash
flutter pub add file_picker  # for local audio import and OPML file picking
flutter analyze
flutter test
```

## Claude Code prompts for this phase

**Prompt 1: search and directory**
```
Read docs/phases/phase-6-search-discovery.md. Build context-aware search on the Subscriptions screen: filter subscriptions live as the user types. Add a "Search Everywhere" button that queries the iTunes Search API. Show results with artwork, title, author, and a Subscribe button. Debounce input 300ms. Full Semantics on search field and results.
```

**Prompt 2: OPML import and export**
```
Implement OPML import and export in lib/features/search/. Import: use file_picker to select a .opml file, parse the xmlUrl attributes, bulk subscribe with progress announced via SemanticsService. Export: generate OPML XML from current subscriptions and share via system share sheet. Add Import and Export buttons to Settings.
```

**Prompt 3: local audio import**
```
Handle "Open In" for audio files on iOS (AppDelegate changes) and file_picker on Android. Copy the file to app documents/library/. Create a synthetic podcast-like entry so imported audio gets the same Quick Actions, queue, stats, and position persistence as podcast episodes. Show imported files in a Library section.
```
