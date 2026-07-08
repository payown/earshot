# Remove-Currently-Playing-Episode-From-Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Removing the episode that is CURRENTLY PLAYING from the Queue stops it and advances to the next queued episode (or clears the player cleanly if nothing's next), instead of leaving the removed episode playing untouched. Removing any other (non-current) episode is completely unaffected.

**Architecture:** Add a new `PlayerService.removeFromQueue(_:context:)` method that mirrors the existing `markCurrentPlayedAndAdvance()` resolve-next-before-remove shape (issue #619's investigation already confirmed this is the right pattern to copy), but does NOT mark the episode played — removing isn't finishing, and per #614 a removal must never affect the "Episodes completed" listening stat. `QueueActionsBuilder`'s `.removeFromQueue` quick action then routes through this new method instead of calling `QueueRepository.cancelFromQueue(_:)` directly. `QueueRepository` itself is untouched and stays fully decoupled from `PlayerService` (one-way dependency preserved, per the existing architecture).

**Tech Stack:** Swift, SwiftUI, SwiftData, XCTest. No new dependencies.

---

## Context for the engineer (you have zero prior context on this codebase)

- `PlayerService` (`EarshotSwift/Earshot/Features/Player/Data/PlayerService.swift`) is the single `@Observable` class owning all playback state (`AVPlayer`, `currentEpisode`, `isPlaying`, etc.). It's injected into every screen via `@Environment(PlayerService.self)`.
- `QueueRepository` (`EarshotSwift/Earshot/Features/Queue/Data/QueueRepository.swift`) is a pure SwiftData repository for the play queue. It has ZERO dependency on `PlayerService` — it only touches `Episode`/`QueueItem` model state. Keep it that way; do not add a `PlayerService` import or dependency to this file.
- `QueueActionsBuilder.swift` (`EarshotSwift/Earshot/Features/QuickActions/Domain/QueueActionsBuilder.swift`) builds the list of swipe/rotor actions for a Queue row (Play now, Remove from queue, Move up/down, etc.). Its `buildQueueActions(...)` function already receives both a `player: PlayerService` and a `context: ModelContext` parameter, so the fix has everything it needs already in scope.
- `nowPlayingEpisodeID: PersistentIdentifier?` (line 72) is `PlayerService`'s `@Observable`-visible mirror of "what episode is currently loaded/playing." Compare against `episode.persistentModelID` to check "is this the currently playing episode."
- `markCurrentPlayedAndAdvance()` (line 875) is the existing, working precedent for "resolve what's next in the queue BEFORE mutating it, then either stop cleanly or play the next episode." Read it once before starting Task 1 below — the new method's shape is a close cousin of it, with one deliberate difference: it must NOT call `QueueRepository.markPlayedAndRemove` (that sets `isPlayed = true`, which would wrongly count an un-finished, merely-removed episode as "completed" in listening stats — this exact concern is why #614 was fixed to dismiss-without-marking-played, and #619 must follow the same rule).
- **Important test-safety constraint, already discovered:** `EarshotTests/QuickActionBuildersTests.swift`'s `removeAction(...)` test helper (line 293) builds queue-action tests with a deliberately UNCONFIGURED `PlayerService()` (never `.configure(context:)`-ed) to keep those tests isolated from full playback machinery. If the new `PlayerService` method reads `self.context` (the store set by `.configure(context:)`) instead of taking `context` as an explicit parameter, it will silently no-op in those tests and break `testRemoveFromQueueNilProviderFocusesFullQueueNeighbor` (which asserts the episode actually left the queue). This is why the new method's signature takes `context: ModelContext` as an explicit parameter — do not change this to read `self.context` instead.
- **Announcement order matters for VoiceOver.** The existing `.removeFromQueue` closure announces `"Removed \(episode.title) from the queue"` unconditionally. The new method, when it advances playback, announces `"Now playing \(nextEpisode.title)"` (mirroring `markCurrentPlayedAndAdvance`'s own second announcement). These must fire in the order a listener would expect: "Removed X from the queue" FIRST, then "Now playing Y" if it advances — never the reverse. Task 2 below moves the "Removed..." announcement to fire before the call to the new method for exactly this reason.

---

## File Structure

- **Modify:** `EarshotSwift/Earshot/Features/Player/Data/PlayerService.swift` — add `removeFromQueue(_:context:)`, a new public method near `markCurrentPlayedAndAdvance()`.
- **Modify:** `EarshotSwift/EarshotTests/AdvancedPlaybackTests.swift` — add unit tests for the new `PlayerService` method in isolation.
- **Modify:** `EarshotSwift/Earshot/Features/QuickActions/Domain/QueueActionsBuilder.swift` — route the `.removeFromQueue` case through the new method, reorder the announcement.
- **Modify:** `EarshotSwift/EarshotTests/QuickActionBuildersTests.swift` — add an integration test proving the quick action itself (not just the underlying method) stops/advances playback.
- **No new files.** No changes to `QueueRepository.swift` (stays fully decoupled from `PlayerService`, per the architecture note above).

---

### Task 1: Add `PlayerService.removeFromQueue(_:context:)`

**Files:**
- Modify: `EarshotSwift/Earshot/Features/Player/Data/PlayerService.swift:904` (insert right after the end of `markCurrentPlayedAndAdvance()`, which currently ends at line 904 with the closing brace)
- Test: `EarshotSwift/EarshotTests/AdvancedPlaybackTests.swift`

- [ ] **Step 1: Write the failing tests**

Open `EarshotSwift/EarshotTests/AdvancedPlaybackTests.swift`. Find the end of the file — the last lines currently look like this (the exact closing of the class):

```swift
        XCTAssertEqual(repo.queue().count, 1)
    }
}
```

Insert a new test section immediately before the final closing `}` of the class (i.e., right after the `test_playFromEpisodeList_alreadyQueued_isNoOp` test's closing `}`, before the class's own closing `}`):

```swift
    // MARK: removeFromQueue stops/advances the current episode (#619)

    func test_removeFromQueue_currentEpisodeWithNextQueued_stopsAndAdvances() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let current = Episode(guid: "current", title: "Current", audioURL: "https://x/current.mp3")
        current.podcast = podcast
        ctx.insert(current)
        let next = Episode(guid: "next", title: "Next", audioURL: "https://x/next.mp3")
        next.podcast = podcast
        ctx.insert(next)
        try? ctx.save()

        let repo = QueueRepository(context: ctx)
        repo.add(current)
        repo.add(next)
        player.play(current)
        XCTAssertEqual(player.nowPlayingEpisodeID, current.persistentModelID, "Precondition: current is playing")

        player.removeFromQueue(current, context: ctx)

        XCTAssertNil(current.queueItem, "Removed episode must leave the queue")
        XCTAssertEqual(player.nowPlayingEpisodeID, next.persistentModelID,
                       "Removing the currently playing episode must advance to the next queued episode")
    }

    func test_removeFromQueue_currentEpisodeWithNothingNext_stopsCleanly() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let current = Episode(guid: "current", title: "Current", audioURL: "https://x/current.mp3")
        current.podcast = podcast
        ctx.insert(current)
        try? ctx.save()

        let repo = QueueRepository(context: ctx)
        repo.add(current)
        player.play(current)

        player.removeFromQueue(current, context: ctx)

        XCTAssertNil(current.queueItem, "Removed episode must leave the queue")
        XCTAssertNil(player.nowPlayingEpisodeID, "Nothing queued after it: the player must clear cleanly")
        XCTAssertFalse(player.isPlaying, "Playback must stop when nothing is next")
    }

    func test_removeFromQueue_currentEpisode_doesNotMarkPlayed() {
        // #619 must follow #614's rule: a removal is not a completion, so it must
        // never inflate the "Episodes completed" listening stat.
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let current = Episode(guid: "current", title: "Current", audioURL: "https://x/current.mp3")
        current.podcast = podcast
        ctx.insert(current)
        try? ctx.save()

        let repo = QueueRepository(context: ctx)
        repo.add(current)
        player.play(current)

        player.removeFromQueue(current, context: ctx)

        XCTAssertFalse(current.isPlayed, "Removing must not be recorded as a completed listen")
        XCTAssertNil(current.playedAt, "Episodes-completed stat must not count this episode")
        XCTAssertTrue(current.inboxDismissed, "Must still dismiss from the inbox, matching #614's cancelFromQueue behavior")
    }

    func test_removeFromQueue_notCurrentEpisode_doesNotAffectPlayback() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let current = Episode(guid: "current", title: "Current", audioURL: "https://x/current.mp3")
        current.podcast = podcast
        ctx.insert(current)
        let other = Episode(guid: "other", title: "Other", audioURL: "https://x/other.mp3")
        other.podcast = podcast
        ctx.insert(other)
        try? ctx.save()

        let repo = QueueRepository(context: ctx)
        repo.add(current)
        repo.add(other)
        player.play(current)

        player.removeFromQueue(other, context: ctx)

        XCTAssertNil(other.queueItem, "The removed (non-current) episode must still leave the queue")
        XCTAssertEqual(player.nowPlayingEpisodeID, current.persistentModelID,
                       "Removing a DIFFERENT episode must not touch what's currently playing")
        XCTAssertTrue(player.isPlaying, "Playback must be undisturbed")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project EarshotSwift/Earshot.xcodeproj -scheme Earshot -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EarshotTests/AdvancedPlaybackTests 2>&1 | tail -60`

Expected: **BUILD FAILED** — `error: value of type 'PlayerService' has no member 'removeFromQueue'` (the method doesn't exist yet). This is the correct red state: a compile failure, not a runtime assertion failure, because the method itself is entirely new.

- [ ] **Step 3: Write the minimal implementation**

Open `EarshotSwift/Earshot/Features/Player/Data/PlayerService.swift`. Find `markCurrentPlayedAndAdvance()` — it currently ends at line 904 with:

```swift
        play(nextEpisode, preparedItem: prepared)
        Announcer.announce("Now playing \(nextEpisode.title)")
    }
```

Insert the new method immediately after that closing `}` (still inside the class body):

```swift

    /// Removes `episode` from the queue (#619). If it's the episode currently
    /// playing, stops it and advances to the next queued episode -- mirrors
    /// ``markCurrentPlayedAndAdvance()``'s resolve-next-before-remove shape, but
    /// does NOT mark the episode played: removing isn't the same as finishing,
    /// and per #614 a removal must not affect the "Episodes completed" listening
    /// stat. Removing any OTHER (not currently playing) episode is unaffected --
    /// a plain queue mutation with no playback side effect, exactly as before.
    ///
    /// Takes `context` explicitly rather than reading the stored `self.context`
    /// so this stays callable (and the plain-removal path stays correct) even
    /// from a `PlayerService` that hasn't been `configure(context:)`-ed, matching
    /// how `QuickActionBuildersTests` deliberately tests queue-action building in
    /// isolation from full playback setup.
    func removeFromQueue(_ episode: Episode, context: ModelContext) {
        let repo = QueueRepository(context: context)

        guard nowPlayingEpisodeID == episode.persistentModelID else {
            repo.cancelFromQueue(episode)
            return
        }

        // Resolve the next episode from the CURRENT queue, before removal --
        // exactly as markCurrentPlayedAndAdvance() does, so nextAdvanceID still
        // sees `episode` in the list when computing "the one after it."
        let queued = repo.queue()
        let nextID = nextAdvanceID(after: episode, in: queued)
        let nextEpisode = queued.first { $0.persistentModelID == nextID }

        flushListeningSession()
        repo.cancelFromQueue(episode)

        guard let nextEpisode else {
            // Nothing queued after this one: stop cleanly with the bar cleared.
            pause()
            isPlaying = false
            setCurrentEpisode(nil)
            updateNowPlayingInfo()
            return
        }

        let prepared = preloadedEpisode?.persistentModelID == nextEpisode.persistentModelID
            ? preloadedItem : nil
        preloadedItem = nil
        preloadedEpisode = nil
        play(nextEpisode, preparedItem: prepared)
        Announcer.announce("Now playing \(nextEpisode.title)")
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project EarshotSwift/Earshot.xcodeproj -scheme Earshot -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EarshotTests/AdvancedPlaybackTests 2>&1 | tail -60`

Expected: **TEST SUCCEEDED**, all 4 new tests pass:
- `test_removeFromQueue_currentEpisodeWithNextQueued_stopsAndAdvances`
- `test_removeFromQueue_currentEpisodeWithNothingNext_stopsCleanly`
- `test_removeFromQueue_currentEpisode_doesNotMarkPlayed`
- `test_removeFromQueue_notCurrentEpisode_doesNotAffectPlayback`

Also confirm no existing test in `AdvancedPlaybackTests` regressed (full suite should show 37 tests, 0 failures — 33 existing + 4 new).

- [ ] **Step 5: Commit**

```bash
git add EarshotSwift/Earshot/Features/Player/Data/PlayerService.swift EarshotSwift/EarshotTests/AdvancedPlaybackTests.swift
git commit -m "feat: add PlayerService.removeFromQueue stop/advance logic (#619)"
```

---

### Task 2: Route the Queue "Remove from queue" action through the new method

**Files:**
- Modify: `EarshotSwift/Earshot/Features/QuickActions/Domain/QueueActionsBuilder.swift:62-68`
- Test: `EarshotSwift/EarshotTests/QuickActionBuildersTests.swift`

- [ ] **Step 1: Write the failing integration test**

Open `EarshotSwift/EarshotTests/QuickActionBuildersTests.swift`. Find `testRemoveFromQueueSoleVisibleRowFocusesNil()` (ends around line 369) — insert a new test right after it, before the `// MARK: #562` comment:

```swift

    func testRemoveFromQueueCurrentEpisodeAdvancesPlayback() {
        // #619: removing the CURRENTLY PLAYING row via the Queue quick action
        // must stop it and advance to the next queued episode, not leave it
        // playing untouched.
        let ctx = TestStore.freshContext()
        let eps = makeQueuedTrio(ctx)
        let player = PlayerService()
        player.configure(context: ctx)
        player.play(eps[0])
        XCTAssertEqual(player.nowPlayingEpisodeID, eps[0].persistentModelID, "Precondition")

        let action = buildQueueActions(
            episode: eps[0],
            order: [.removeFromQueue],
            moveMode: .flat,
            player: player,
            downloads: DownloadManager(),
            context: ctx,
            onShowNotes: {},
            onFocus: { _ in }
        ).first

        action?.run()

        XCTAssertNil(eps[0].queueItem, "The removed episode must leave the queue")
        XCTAssertEqual(player.nowPlayingEpisodeID, eps[1].persistentModelID,
                       "Removing the row that's currently playing must advance to the next queued episode")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project EarshotSwift/Earshot.xcodeproj -scheme Earshot -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EarshotTests/QuickActionBuildersTests/testRemoveFromQueueCurrentEpisodeAdvancesPlayback 2>&1 | tail -40`

Expected: **TEST FAILED** — `XCTAssertEqual failed: ("nil") is not equal to ("Optional(eps[1].persistentModelID)")`. This confirms the current `.removeFromQueue` case (still calling `repo.cancelFromQueue` directly) does not advance playback yet.

- [ ] **Step 3: Update `QueueActionsBuilder.swift`**

Open `EarshotSwift/Earshot/Features/QuickActions/Domain/QueueActionsBuilder.swift`. Find:

```swift
        case .removeFromQueue:
            return QuickActionItem(label: "Remove from queue", isDestructive: true) {
                let neighbor = neighborID(of: episode, in: visibleQueue?() ?? repo.queue())
                repo.cancelFromQueue(episode)
                Announcer.announce("Removed \(episode.title) from the queue")
                onFocus(neighbor)
            }
```

Replace it with:

```swift
        case .removeFromQueue:
            return QuickActionItem(label: "Remove from queue", isDestructive: true) {
                let neighbor = neighborID(of: episode, in: visibleQueue?() ?? repo.queue())
                // Announce the removal BEFORE calling into PlayerService (#619):
                // if `episode` is the one currently playing, removeFromQueue may
                // itself announce "Now playing <next>" -- that must come SECOND,
                // matching the order a listener expects ("removed X" then "now
                // playing Y"), not before it.
                Announcer.announce("Removed \(episode.title) from the queue")
                player.removeFromQueue(episode, context: context)
                onFocus(neighbor)
            }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -project EarshotSwift/Earshot.xcodeproj -scheme Earshot -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EarshotTests/QuickActionBuildersTests/testRemoveFromQueueCurrentEpisodeAdvancesPlayback 2>&1 | tail -40`

Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -project EarshotSwift/Earshot.xcodeproj -scheme Earshot -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -80`

Expected: **TEST SUCCEEDED**, 0 failures. In particular, confirm these 4 PRE-EXISTING tests in `QuickActionBuildersTests` still pass unchanged (they use an unconfigured `PlayerService()`, so `nowPlayingEpisodeID` is nil and the new code takes the plain-removal fast path, same as before):
- `testRemoveFromQueueNilProviderFocusesFullQueueNeighbor`
- `testRemoveFromQueueVisibleQueueFocusesNeighborWithinSubset`
- `testRemoveFromQueueLastVisibleRowFallsBackToPreviousVisible`
- `testRemoveFromQueueSoleVisibleRowFocusesNil`

And confirm `QueueRepositoryTests` still passes in full (no changes were made to `QueueRepository.swift`, but re-verify nothing else in the suite was disturbed).

- [ ] **Step 6: Commit**

```bash
git add EarshotSwift/Earshot/Features/QuickActions/Domain/QueueActionsBuilder.swift EarshotSwift/EarshotTests/QuickActionBuildersTests.swift
git commit -m "fix: removing the currently-playing episode from the queue now stops/advances playback (closes #619)"
```

---

### Task 3: Accessibility review, full build verification, PR

**Files:** None (verification and process only).

- [ ] **Step 1: Run the `mobile-accessibility` agent**

This change alters the VoiceOver announcement sequence for the "Remove from queue" action (now potentially two sequential announcements: "Removed X from the queue" then "Now playing Y"). Per project rule, every PR touching user-facing behavior needs an accessibility gate before merge. Dispatch the `mobile-accessibility` agent with the diff from Tasks 1-2, specifically asking it to verify:
- The two-announcement sequence order is correct and not confusing (Removed X, then Now playing Y — never the reverse).
- No new announcement fires when removing a non-current episode (must stay silent on the playback side, exactly as before).
- The "stop cleanly" path (nothing queued after) doesn't leave a stale or misleading Now Playing bar / VoiceOver state.

- [ ] **Step 2: Full build + test verification**

Run: `xcodebuild build -project EarshotSwift/Earshot.xcodeproj -scheme Earshot -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30`

Expected: **BUILD SUCCEEDED**, no errors.

Run: `xcodebuild test -project EarshotSwift/Earshot.xcodeproj -scheme Earshot -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -80`

Expected: **TEST SUCCEEDED**, 0 failures across the entire suite.

- [ ] **Step 3: Push branch and open PR**

```bash
git checkout -b fix/remove-current-episode-from-queue
git push -u origin fix/remove-current-episode-from-queue
gh pr create --repo payown/earshot --base swift \
  --title "fix: removing the currently-playing episode from the queue stops/advances playback" \
  --body "Closes #619. Removing the episode that's currently playing from the Queue now stops it and advances to the next queued episode (or clears the player cleanly if nothing's next), mirroring the existing markCurrentPlayedAndAdvance() pattern -- but without marking the episode played, per #614's rule that a removal must not affect the Episodes completed listening stat. Removing any other (non-current) episode is unaffected."
```

(Branch note: create the branch at the START of Task 1 in practice, not at the end here — this plan lists it last only because the skill template groups process/PR steps together. Do not work directly on `swift`.)

- [ ] **Step 4: Wait for Michael's device verification before merging**

Per project rule, do not merge, close #619, or move to the next issue until Michael confirms this works on his device: remove the currently-playing episode from the Queue and confirm it stops and advances (or clears cleanly) instead of continuing to play the removed episode.

---

## Definition of Done

- [ ] `PlayerService.removeFromQueue(_:context:)` exists, tested in isolation (4 tests).
- [ ] `QueueActionsBuilder`'s `.removeFromQueue` case routes through it, tested via an integration test that exercises the real quick action.
- [ ] Removing the currently-playing episode stops it and advances (or clears cleanly if nothing's queued after it).
- [ ] Removing any other episode is provably unaffected (existing tests pass unchanged + new regression test).
- [ ] The removed episode is never marked played (`isPlayed`/`playedAt` untouched), consistent with #614.
- [ ] VoiceOver announcement order is "Removed X" then "Now playing Y" (never reversed), reviewed by `mobile-accessibility`.
- [ ] Full test suite green, build clean.
- [ ] PR opened against `swift`, merge withheld until Michael confirms on device.
