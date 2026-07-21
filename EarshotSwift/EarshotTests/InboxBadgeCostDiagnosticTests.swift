import XCTest
import SwiftData
@testable import Earshot

/// Before/after measurement for the inbox-badge CPU-kill fix (branch
/// `fix/inbox-badge-cpu-kill`). Diagnostic only — skipped unless
/// `RUN_BADGE_DIAG=1`. Run with the TEST_RUNNER_ prefix so xctest injects it:
///
///   TEST_RUNNER_RUN_BADGE_DIAG=1 xcodebuild test ... \
///     -only-testing:EarshotTests/InboxBadgeCostDiagnosticTests
///
/// Seeds a heavy-listener library — mostly PLAYED history, few new episodes,
/// nothing dismissed (finished episodes are never dismissed in production, which
/// is exactly why the old query grew without bound). Then times the work the
/// always-mounted `RootView.InboxTabBadge` does on EACH 5-second playback-position
/// save, both ways, on identical data:
///
///   BEFORE = fetch `InboxQuery.normal` (every non-dismissed episode) + count
///            `.newEpisode` in memory   (the shipped build 152/153 behavior)
///   AFTER  = fetch `InboxQuery.normalUnplayed` (adds `playedAt == nil`) + count
///            `.newEpisode` in memory   (the fix)
///
/// Both must return the SAME badge number; only the cost differs. Also sums 12
/// consecutive passes to approximate one minute of playback (a save every ~5s),
/// which is the window iOS's `cpu_resource_fatal` limit (80% CPU / 60s) measures.
@MainActor
final class InboxBadgeCostDiagnosticTests: XCTestCase {

    /// (total episodes, fraction already played). Non-dismissed throughout.
    private let scenarios: [(total: Int, playedFraction: Double)] = [
        (5_000, 0.9),
        (15_000, 0.9),
    ]

    func test_badgeCostBeforeAfter() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_BADGE_DIAG"] != nil,
            "Set RUN_BADGE_DIAG=1 to run the badge-cost diagnostic (diagnostic only)."
        )

        print("BADGEDIAG|header|total|played|new|beforeMs_1x|afterMs_1x|before_12x|after_12x|beforeCount|afterCount")

        for scenario in scenarios {
            let container = try ModelContainerFactory.makeInMemory()
            let ctx = container.mainContext
            let podcast = Podcast(feedURL: "https://feed.test/diag.xml", title: "Diag")
            ctx.insert(podcast)

            let playedTarget = Int(Double(scenario.total) * scenario.playedFraction)
            var played = 0
            for i in 0..<scenario.total {
                let e = Episode(
                    guid: "ep-\(i)",
                    title: "Episode \(i)",
                    audioURL: "https://feed.test/\(i).mp3",
                    pubDate: Date(timeIntervalSince1970: TimeInterval(i)),
                    status: .newEpisode,
                    inboxDismissed: false
                )
                e.podcast = podcast
                // Mark the played fraction through the real setter so `playedAt`
                // is set exactly as production does (this is the field the fix
                // keys off). The rest stay `.newEpisode` (the actual inbox).
                if played < playedTarget {
                    e.isPlayed = true
                    played += 1
                }
                ctx.insert(e)
                if i % 5_000 == 4_999 { try? ctx.save() }
            }
            try? ctx.save()
            let newCount = scenario.total - played

            // BEFORE: the shipped badge path.
            var beforeCount = 0
            let before1x = measureMs {
                let all = (try? ctx.fetch(FetchDescriptor<Episode>(predicate: InboxQuery.normal))) ?? []
                beforeCount = all.filter { $0.status == .newEpisode }.count
            }
            // AFTER: the fixed badge path.
            var afterCount = 0
            let after1x = measureMs {
                let unplayed = (try? ctx.fetch(FetchDescriptor<Episode>(predicate: InboxQuery.normalUnplayed))) ?? []
                afterCount = unplayed.filter { $0.status == .newEpisode }.count
            }

            // One simulated minute of playback: a position save every ~5s = 12
            // badge recomputes. This is the work that must stay under iOS's
            // 80%-CPU-over-60s limit.
            let before12x = measureMs {
                for _ in 0..<12 {
                    autoreleasepool {
                        let all = (try? ctx.fetch(FetchDescriptor<Episode>(predicate: InboxQuery.normal))) ?? []
                        _ = all.filter { $0.status == .newEpisode }.count
                    }
                }
            }
            let after12x = measureMs {
                for _ in 0..<12 {
                    autoreleasepool {
                        let unplayed = (try? ctx.fetch(FetchDescriptor<Episode>(predicate: InboxQuery.normalUnplayed))) ?? []
                        _ = unplayed.filter { $0.status == .newEpisode }.count
                    }
                }
            }

            print(String(
                format: "BADGEDIAG|row|%d|%d|%d|%.1f|%.1f|%.1f|%.1f|%d|%d",
                scenario.total, played, newCount,
                before1x, after1x, before12x, after12x, beforeCount, afterCount
            ))

            // The whole point: the badge number is identical, only the cost drops.
            XCTAssertEqual(beforeCount, afterCount, "badge count must be unchanged by the fix")
            XCTAssertEqual(afterCount, newCount)
        }
    }

    private func measureMs(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }
}
