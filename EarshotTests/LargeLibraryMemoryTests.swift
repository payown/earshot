import XCTest
import SwiftData
import Darwin
@testable import Earshot

/// Large-library memory / cost profile for the #696 OOM investigation.
///
/// The 332-podcast TestFlight tester hit a memory-pressure jetsam ("slower and
/// slower, then crashes, then won't reopen"). Unlike ``ScaleDiagnosticTests``
/// (one episode per podcast), this builds a REALISTIC shape — many episodes per
/// podcast and a large non-dismissed inbox — because it's the total `Episode`
/// row count and the unbounded full-table materializations that drive the OOM,
/// not the podcast count alone.
///
/// It measures the three hot paths the code investigation flagged, at each
/// scale, printing resident-memory (RSS) deltas so a regression shows up as a
/// number:
///   1. Full `FetchDescriptor<Episode>()` — the `mergeBackgroundWrites` cost
///      that runs on every launch / resume / refresh / import.
///   2. `InboxRepository.inboxEpisodes()` — the inbox load (worst scaler, #548).
///   3. The `autoDownloadRecent` resolution pattern — one main-context predicate
///      fetch PER episode ID (the build-150 import re-materialization).
///
/// Env-gated so it never runs in the normal suite. xcodebuild only forwards env
/// vars prefixed with `TEST_RUNNER_` into the on-simulator test process, so run:
///   TEST_RUNNER_RUN_LARGE_LIB=1 xcodebuild test ... \
///     -only-testing:EarshotTests/LargeLibraryMemoryTests
///
/// Optional overrides (also `TEST_RUNNER_`-prefixed at the xcodebuild layer):
///   RUN_LARGE_LIB_SCALES="1000,10000"   podcast counts (default "1000")
///   RUN_LARGE_LIB_EPISODES="60"         episodes per podcast (default 60)
@MainActor
final class LargeLibraryMemoryTests: XCTestCase {

    func test_largeLibraryMemoryProfile() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["RUN_LARGE_LIB"] != nil,
            "Set RUN_LARGE_LIB=1 (TEST_RUNNER_RUN_LARGE_LIB=1 via xcodebuild) to run the large-library memory profile."
        )

        let scales = (env["RUN_LARGE_LIB_SCALES"] ?? "1000")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let episodesPerPodcast = Int(env["RUN_LARGE_LIB_EPISODES"] ?? "") ?? 60

        print("LARGELIB|header|podcasts|episodes|buildMs|baseRssMB|fullEpisodeFetchMs|fullEpisodeFetchRssMB|inboxLoadMs|inboxLoadRssMB|unboundedResolveMs|boundedResolveMs")

        for podcastCount in scales {
            // Fresh in-memory store per scale so numbers are independent and an
            // OOM at one scale is a legitimate, isolated finding.
            let container = try ModelContainerFactory.makeInMemory()
            let context = container.mainContext

            let buildMs = measureMs {
                autoreleasepool {
                    var sinceSave = 0
                    for p in 0..<podcastCount {
                        let podcast = Podcast(
                            feedURL: "https://feed.test/\(p)/rss.xml",
                            title: Self.title(for: p)
                        )
                        context.insert(podcast)
                        for e in 0..<episodesPerPodcast {
                            let idx = p * episodesPerPodcast + e
                            let episode = Episode(
                                guid: "ep-\(idx)",
                                title: "Episode \(idx)",
                                audioURL: "https://feed.test/\(p)/\(e).mp3",
                                pubDate: Date(timeIntervalSince1970: TimeInterval(idx)),
                                status: .newEpisode,
                                // Leave the newest 3 per podcast in the inbox
                                // (the default seed), the rest dismissed — a
                                // realistic steady state, ~3x podcastCount inbox.
                                inboxDismissed: e < episodesPerPodcast - 3
                            )
                            episode.podcast = podcast
                            context.insert(episode)
                            sinceSave += 1
                            if sinceSave >= 5_000 {
                                try? context.save()
                                sinceSave = 0
                            }
                        }
                    }
                    try? context.save()
                }
            }
            let baseRss = Self.residentMemoryMB()

            // 1. Full Episode table fetch (mergeBackgroundWrites hot path). Reuse
            // its result to collect PERMANENT per-podcast IDs (persistentModelID
            // is only stable post-save, so we read them here, not during build).
            var allEpisodes: [Episode] = []
            let fullFetchMs = measureMs {
                autoreleasepool {
                    allEpisodes = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
                }
            }
            let fullFetchRss = Self.residentMemoryMB()

            var idsByPodcast: [PersistentIdentifier: [PersistentIdentifier]] = [:]
            for episode in allEpisodes {
                guard let pid = episode.podcast?.persistentModelID else { continue }
                idsByPodcast[pid, default: []].append(episode.persistentModelID)
            }
            let episodeIDsPerPodcast = Array(idsByPodcast.values)

            // 2. Inbox load (the exact call RootView badge + Inbox screen make).
            let inbox = InboxRepository(context: context)
            var inboxCount = 0
            let inboxMs = measureMs {
                autoreleasepool {
                    inboxCount = inbox.inboxEpisodes().count
                }
            }
            let inboxRss = Self.residentMemoryMB()

            // 3a. OLD auto-download resolution: one predicate fetch per episode ID
            // across the WHOLE import (the build-150 re-materialization).
            var unboundedResolved = 0
            let unboundedMs = measureMs {
                autoreleasepool {
                    for ids in episodeIDsPerPodcast {
                        for id in ids {
                            if resolve(id, in: context) != nil { unboundedResolved += 1 }
                        }
                    }
                }
            }

            // 3b. NEW behaviour (#696 fix): the actor now returns only the newest
            // `autoDownloadIDCap` IDs per podcast, so the main context resolves at
            // most that many per feed. Mirror that here to show the reduction.
            let cap = 10
            var boundedResolved = 0
            let boundedMs = measureMs {
                autoreleasepool {
                    for ids in episodeIDsPerPodcast {
                        for id in ids.suffix(cap) { // newest-by-insert proxy
                            if resolve(id, in: context) != nil { boundedResolved += 1 }
                        }
                    }
                }
            }

            print(String(
                format: "LARGELIB|row|%d|%d|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f (episodesFetched=%d inbox=%d unboundedResolved=%d boundedResolved=%d)",
                podcastCount, episodesPerPodcast, buildMs, baseRss,
                fullFetchMs, fullFetchRss, inboxMs, inboxRss,
                unboundedMs, boundedMs,
                allEpisodes.count, inboxCount, unboundedResolved, boundedResolved
            ))
        }

        XCTAssertFalse(scales.isEmpty, "No scales parsed from RUN_LARGE_LIB_SCALES.")
    }

    // MARK: Helpers

    /// Mirrors `SubscriptionRepository.episode(forPersistentID:)` — one bounded
    /// predicate fetch on the main context.
    private func resolve(_ id: PersistentIdentifier, in context: ModelContext) -> Episode? {
        var d = FetchDescriptor<Episode>(predicate: #Predicate { $0.persistentModelID == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    private func measureMs(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }

    private static func title(for index: Int) -> String {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let a = letters[letters.index(letters.startIndex, offsetBy: index % 26)]
        let b = letters[letters.index(letters.startIndex, offsetBy: (index / 26) % 26)]
        return "\(a)\(b) Podcast \(index)"
    }

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
