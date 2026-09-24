# Expanded podcast directory search

StartTesting feature: `557999fa-2fa5-4211-bd7d-374a47a9df17`.

Directory searches now request up to 200 matches instead of 25, using the maximum
in [Apple's iTunes Search API documentation](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/Searching.html).
The provider may return fewer matches, and entries without usable feeds or with
duplicate feeds are still removed. The app preserves provider relevance order.

The existing SearchView hands all surviving matches to DirectoryPodcastResults.
No presentation cap needed removal. Its existing debounce, task cancellation,
retry, result-count announcements, row labels, actions, and focus semantics remain
unchanged. Feed-description fetching remains off-main with two concurrent requests
and session caching; it can fetch more descriptions in total for broader results.
No schema, settings, signing, entitlement, or purchase changes.

## Validation

- Xcode 27.0, iOS 26.5 simulator: all 34 focused tests passed across
  ITunesSearchServiceTests, SearchScopeTests, SearchResultPositionTests, and
  DirectoryPodcastDescriptionServiceTests.

- A live public-directory request for `science` with `limit=200` returned 99
  results with 99 distinct feed URLs on September 24. This demonstrates provider
  results beyond 25; it is not a guarantee of 200 matches for every query.
- Network-fixture regression requests 200 once and processes all 200 entries,
  including duplicate and missing-feed entries beyond the old boundary. It
  verifies 198 unique valid results in exact relevance order through result 200.
- Query-injection regression now attempts to inject limit 999 and verifies that
  the service keeps exactly one limit parameter with value 200.
- Physical-device search and VoiceOver responsiveness remain to be checked.

## Phone acceptance

Search Add Podcast for a broad term such as `science`. Confirm more than 25
results when the directory supplies them, navigate to later results, open a
podcast and return. Change the query rapidly and confirm old matches do not
replace the new query. Check VoiceOver count announcements, row navigation and
Follow actions, and confirm responsiveness while descriptions load.
