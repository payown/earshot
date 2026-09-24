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

## Dictation-stop responsiveness follow-up

Michael reported a brief period of app unresponsiveness in the installed search:
double-tap the edit field, two-finger double-tap to start iOS dictation, then
two-finger double-tap to stop. This is on-device VoiceOver evidence. Exact query,
playback state and duration were not supplied; no device trace was captured.

The directory renderer scanned every followed podcast separately for each
result's Following state and description, repeatedly canonicalizing both feed
URLs on the main actor. The 200-result allowance amplifies this existing cost.
A render-local canonical-feed index now replaces those repeated scans. First
matching podcast wins as before, including a nil local description; metadata
and follow/unfollow updates rebuild from the current query. The index does not
load episode relationships. Row labels, values, rotor actions and focus modifiers
remain unchanged. The full-description action reuses the rendered description.

Evidence boundaries:

- Synthetic Mac test, 1,000 library feeds and 200 unmatched directory feeds:
  two old scans per result took 1.121 seconds; index construction plus lookup
  took 0.0018 seconds. This is a synthetic code-path measurement, not phone latency.
- Simulator regression, 1,000 podcasts and 200 results (half matching): one old
  scan per result took 0.333 seconds; the production index took 0.0031 seconds.
  Every model match was identical. Timing is diagnostic, not a flaky test limit.
- All 26 focused service/description/index tests passed. They cover canonical
  aliases, duplicate first-match precedence, nil metadata, metadata changes,
  follow/unfollow reconstruction, and expanded-result lookup equivalence.
- These measurements establish avoidable work, not that it is the sole cause of
  the reported dictation stall. Physical acceptance must repeat Michael's exact
  steps, then immediately navigate results with VoiceOver. Description loading,
  accessibility-tree updates and audio interruption/resume remain profiling leads
  if the stall persists.
- Initial PR CI failed due to simulator app launch/preflight Busy errors; that
  failure does not establish a search assertion regression. A new commit reruns CI.

Final local validation for the lookup fix: full eligible unit suite passed with
2,372 passed, 33 skipped, zero failures (documented StoreKit suites excluded).
Signed Release build and strict signature verification passed.

Merge-gate follow-up: the next CI run passed 2,404 tests but failed one existing
largest-text unfollow UI assertion. Library can appear under the dismissing
Podcast Settings sheet before the sheet leaves the accessibility tree. The test
now waits up to five seconds for both outgoing surfaces to disappear rather than
asserting disappearance synchronously. Both normal- and largest-text unfollow
UI tests passed locally (two tests, zero failures). No production change in this
follow-up; CI reruns on the new commit.
