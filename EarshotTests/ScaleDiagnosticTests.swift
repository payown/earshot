import XCTest
import SwiftData
import Darwin
@testable import Earshot

/// Diagnostic-only synthetic-library scale profile (2026-07-02 overnight session).
///
/// Measures how the data-layer operations that back the main screens behave as the
/// library grows to 10, 100, 1_000, 10_000, and 100_000 podcasts. These are
/// data-layer proxies, not full UI timings: true launch/scroll timing needs an
/// XCUITest harness + Instruments on device (there are no UI tests yet, #388). But
/// the fetch/sort work measured here is what dominates the screens' cost at scale,
/// so it's the right signal for where performance work should focus (see
/// claude_work_july_2.md Phase 6).
///
/// Skipped by default so it never slows the normal suite. Run explicitly with:
///   RUN_SCALE_DIAG=1 xcodebuild test ... -only-testing:EarshotTests/ScaleDiagnosticTests
///
/// The library is grown CUMULATIVELY through each checkpoint and a marker row is
/// printed immediately after each measurement, so partial results survive even if
/// a high scale hangs or exhausts memory (which is itself a finding to report).
@MainActor
final class ScaleDiagnosticTests: XCTestCase {

    /// One inbox-eligible episode per podcast (status `.newEpisode`, not dismissed),
    /// so the inbox candidate set grows with the library — a worst case that
    /// exercises the inbox query's ceiling rather than the capped steady state.
    private let checkpoints = [10, 100, 1_000, 10_000, 100_000]

    func test_libraryScaleProfile() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_SCALE_DIAG"] != nil,
            "Set RUN_SCALE_DIAG=1 to run the scale diagnostic (slow; diagnostic only)."
        )

        // Own in-memory container so the shared TestStore isn't polluted and disk
        // I/O doesn't add noise. (In-memory also means a 100k run stresses real RAM
        // — an OOM there is a legitimate finding.)
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let inbox = InboxRepository(context: context)

        print("SCALEDIAG|header|scale|insertMs|loadSubsMs|loadInboxMs|peakRssMB")

        var inserted = 0
        for scale in checkpoints {
            // Cumulatively insert the delta to reach this scale.
            let insertMs = measureMs {
                autoreleasepool {
                    var sinceSave = 0
                    while inserted < scale {
                        let podcast = Podcast(
                            feedURL: "https://feed.test/\(inserted)/rss.xml",
                            title: Self.title(for: inserted)
                        )
                        context.insert(podcast)
                        let episode = Episode(
                            guid: "ep-\(inserted)",
                            title: "Episode \(inserted)",
                            audioURL: "https://feed.test/\(inserted)/audio.mp3",
                            pubDate: Date(timeIntervalSince1970: TimeInterval(inserted)),
                            status: .newEpisode,
                            inboxDismissed: false
                        )
                        episode.podcast = podcast
                        context.insert(episode)
                        inserted += 1
                        sinceSave += 1
                        // Batch saves so a huge insert doesn't hold everything
                        // un-persisted, mirroring FeedRefreshActor's batching.
                        if sinceSave >= 5_000 {
                            try? context.save()
                            sinceSave = 0
                        }
                    }
                    try? context.save()
                }
            }

            // Subscriptions load proxy: the fetch + in-memory title sort that
            // SubscriptionsView does (@Query(sort: \.title) then LibrarySort).
            var podcastCount = 0
            let loadSubsMs = measureMs {
                autoreleasepool {
                    let descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)])
                    let podcasts = (try? context.fetch(descriptor)) ?? []
                    let sorted = podcasts.sorted { LibrarySort.titlesInOrder($0.title, $1.title) }
                    podcastCount = sorted.count
                }
            }

            // Inbox load proxy: InboxRepository.inboxEpisodes() — the exact call the
            // Inbox screen and the RootView badge run.
            var inboxCount = 0
            let loadInboxMs = measureMs {
                autoreleasepool {
                    inboxCount = inbox.inboxEpisodes().count
                }
            }

            let rssMB = Self.residentMemoryMB()
            print(String(
                format: "SCALEDIAG|row|%d|%.1f|%.1f|%.1f|%.1f (podcasts=%d inbox=%d)",
                scale, insertMs, loadSubsMs, loadInboxMs, rssMB, podcastCount, inboxCount
            ))
        }

        // Always passes — this profiles, it doesn't assert a threshold.
        XCTAssertGreaterThan(inserted, 0)
    }

    // MARK: Helpers

    /// Elapsed wall-clock milliseconds for `work`.
    private func measureMs(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }

    /// A spread of titles so the title sort does real comparison work rather than
    /// sorting a run of identical strings.
    private static func title(for index: Int) -> String {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let a = letters[letters.index(letters.startIndex, offsetBy: index % 26)]
        let b = letters[letters.index(letters.startIndex, offsetBy: (index / 26) % 26)]
        return "\(a)\(b) Podcast \(index)"
    }

    /// Resident set size in MB via mach task info, or -1 if unavailable.
    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
}
