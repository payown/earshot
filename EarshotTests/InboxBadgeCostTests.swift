import XCTest
import SwiftData
@testable import Earshot

/// Diagnostic measurement for the "phone gets hot during long playback"
/// investigation. The Inbox tab badge (`InboxTabBadge` in RootView) re-runs its
/// `@Query(filter: InboxQuery.normalUnplayed)` on EVERY position save (~every 5
/// playback-seconds), then walks the result in memory with
/// `.filter { $0.status == .newEpisode }.count`. At 1.5x, saves fire ~1.5x more
/// often in wall-clock. This times exactly that per-save badge recompute at a
/// small vs. a large (heavy-user) library so we can see how it scales.
///
/// This is not an assertion-heavy test — it prints timings. It becomes the
/// regression baseline once the badge is decoupled from position saves.
@MainActor
final class InboxBadgeCostTests: XCTestCase {

    /// Seeds `podcasts` shows, each with `unplayedEach` unplayed .newEpisode
    /// episodes (badge-eligible) and `playedEach` played episodes (excluded by
    /// the `playedAt == nil` predicate — present to prove they don't count).
    private func seed(_ ctx: ModelContext, podcasts: Int, unplayedEach: Int, playedEach: Int) {
        for p in 0..<podcasts {
            let podcast = Podcast(feedURL: "https://x/feed\(p)", title: "Show \(p)")
            ctx.insert(podcast)
            for e in 0..<unplayedEach {
                let ep = Episode(guid: "u-\(p)-\(e)", title: "Ep \(e)", audioURL: "https://x/\(p)-\(e).mp3")
                ep.podcast = podcast
                ctx.insert(ep)
            }
            for e in 0..<playedEach {
                let ep = Episode(guid: "p-\(p)-\(e)", title: "Played \(e)", audioURL: "https://x/p\(p)-\(e).mp3",
                                 status: .played, playedAt: .distantPast)
                ep.podcast = podcast
                ctx.insert(ep)
            }
        }
        try? ctx.save()
    }

    /// One badge recompute, exactly as `InboxTabBadge.body` does it: the store
    /// fetch on `normalUnplayed` followed by the in-memory `.newEpisode` count.
    private func oneBadgeRecompute(_ ctx: ModelContext) -> (count: Int, seconds: Double) {
        let fd = FetchDescriptor<Episode>(predicate: InboxQuery.normalUnplayed)
        let t0 = CFAbsoluteTimeGetCurrent()
        let fetched = (try? ctx.fetch(fd)) ?? []
        let count = fetched.filter { $0.status == .newEpisode }.count
        return (count, CFAbsoluteTimeGetCurrent() - t0)
    }

    /// Median of several recomputes (SwiftData warms after the first fetch).
    private func medianRecompute(_ ctx: ModelContext, iterations: Int = 7) -> (count: Int, ms: Double) {
        var samples: [Double] = []
        var last = 0
        for _ in 0..<iterations {
            let r = oneBadgeRecompute(ctx)
            last = r.count
            samples.append(r.seconds * 1000)
        }
        samples.sort()
        return (last, samples[samples.count / 2])
    }

    func test_badgeRecomputeCost_smallVsLargeLibrary() {
        // Small: a light user.
        let small = TestStore.freshContext()
        seed(small, podcasts: 2, unplayedEach: 5, playedEach: 5)
        let s = medianRecompute(small)

        // Large: a heavy user's backlog — 250 shows x 60 unplayed = 15,000
        // badge-eligible episodes, plus 250 x 40 = 10,000 played (excluded).
        let large = TestStore.freshContext()
        seed(large, podcasts: 250, unplayedEach: 60, playedEach: 40)
        let l = medianRecompute(large)

        // Extrapolate to sustained main-thread load. At 1.5x, a position save
        // fires ~every 3.3s wall-clock => ~18 badge recomputes/minute.
        let recomputesPerMin = 18.0
        let smallLoadMsPerMin = s.ms * recomputesPerMin
        let largeLoadMsPerMin = l.ms * recomputesPerMin

        print("""

        ===== INBOX BADGE PER-SAVE COST (heat investigation) =====
        SMALL library: \(s.count) badge episodes -> \(String(format: "%.2f", s.ms)) ms/recompute
        LARGE library: \(l.count) badge episodes -> \(String(format: "%.2f", l.ms)) ms/recompute
        Scale factor (large/small): \(String(format: "%.1fx", l.ms / max(s.ms, 0.0001)))

        At 1.5x playback (~18 badge recomputes/min, one per position save):
          SMALL: ~\(String(format: "%.0f", smallLoadMsPerMin)) ms/min of main-thread work
          LARGE: ~\(String(format: "%.0f", largeLoadMsPerMin)) ms/min of main-thread work
                 (~\(String(format: "%.1f", largeLoadMsPerMin / 600.0))% of one core, sustained, over an 89-min listen)
        ==========================================================
        """)

        XCTAssertEqual(l.count, 15_000, "large seed should expose 15k badge-eligible episodes")
        XCTAssertGreaterThan(l.ms, s.ms, "badge recompute must scale up with library size")
    }

    /// Validates the proposed fix's core assumption: a store-level `fetchCount`
    /// on the same predicate (no object materialization) is orders of magnitude
    /// cheaper than the current fetch-all-and-filter, so it's safe to run on
    /// every position save as a change-detector.
    func test_fetchCountIsCheapEnoughToRunPerSave() {
        let ctx = TestStore.freshContext()
        seed(ctx, podcasts: 250, unplayedEach: 60, playedEach: 40)

        // Current approach: materialize candidates + in-memory filter.
        var fullSamples: [Double] = []
        for _ in 0..<7 { fullSamples.append(oneBadgeRecompute(ctx).seconds * 1000) }
        fullSamples.sort()
        let fullMs = fullSamples[fullSamples.count / 2]

        // Proposed detector: pure SQL COUNT, no objects loaded.
        var countSamples: [Double] = []
        var countValue = 0
        for _ in 0..<7 {
            let fd = FetchDescriptor<Episode>(predicate: InboxQuery.normalUnplayed)
            let t0 = CFAbsoluteTimeGetCurrent()
            countValue = (try? ctx.fetchCount(fd)) ?? -1
            countSamples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        countSamples.sort()
        let countMs = countSamples[countSamples.count / 2]

        print("""

        ===== fetchCount vs materialize-and-filter (15k candidates) =====
        Current (fetch + in-memory filter): \(String(format: "%.2f", fullMs)) ms
        Proposed (fetchCount, SQL COUNT):   \(String(format: "%.2f", countMs)) ms
        Speedup: \(String(format: "%.0fx", fullMs / max(countMs, 0.0001)))
        (candidate count = \(countValue))
        ================================================================
        """)

        // The detector must be dramatically cheaper to be safe per-save.
        XCTAssertLessThan(countMs, fullMs / 10, "fetchCount must be >=10x cheaper than materialize+filter")
    }
}
