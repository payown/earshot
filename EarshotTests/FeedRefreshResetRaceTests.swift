import SwiftData
import XCTest
import Darwin
@testable import Earshot

private actor InFlightFeedFetcher: FeedFetching {
    private let feed: ParsedFeed
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(feed: ParsedFeed) { self.feed = feed }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        started = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
final class FeedRefreshResetRaceTests: XCTestCase {
    func testResetCancelsInFlightRefreshBeforeDisposableFileReset() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        context.insert(Podcast(feedURL: "https://example.com/feed.xml", title: "Example"))
        try context.save()

        let feed = ParsedFeed(
            title: "Example", artworkURL: nil, description: nil, author: nil,
            websiteURL: nil, language: nil, category: nil, episodes: []
        )
        let fetcher = InFlightFeedFetcher(feed: feed)
        let refresh = Task { @MainActor in
            await BackgroundFeedRefresher.runRefresh(
                container: container, force: true, notifier: NotificationService(), feed: fetcher
            )
        }
        await fetcher.waitUntilStarted()

        let root = FileManager.default.temporaryDirectory
            .appending(path: "EarshotFeedResetRace-\(UUID().uuidString)", directoryHint: .isDirectory)
        let applicationSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = AppRuntime(
            mode: .testHost,
            fileResetOperation: {
                await SettingsReset.performFileReset(
                    applicationSupport: applicationSupport,
                    documents: documents,
                    caches: caches
                )
            }
        )

        let reset = await runtime.resetLocalData()
        let refreshResult = await refresh.value

        XCTAssertTrue(reset)
        XCTAssertFalse(refreshResult)
        XCTAssertFalse(ModelContainerFactory.hasStoreFiles(
            at: applicationSupport.appending(path: "default.store")
        ))
    }

    func testFiveRunShippingResetTimingWithRefreshCancellationPath() async throws {
        var samples: [Double] = []
        var peaks: [Double] = []
        for run in 1...5 {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "EarshotShippingReset-\(UUID().uuidString)", directoryHint: .isDirectory)
            let applicationSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
            let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
            let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let primary = applicationSupport.appending(path: "default.store")
            guard case .ready = await ModelContainerFactory.makeShared(
                using: StoreMigrationEngine(), at: primary
            ) else { return XCTFail("disposable store did not open") }
            let start = DispatchTime.now().uptimeNanoseconds
            let ok = await SettingsReset.performFileReset(
                applicationSupport: applicationSupport, documents: documents, caches: caches
            )
            guard ok else { return XCTFail("reset failed on run \(run)") }
            guard case .ready = await ModelContainerFactory.makeShared(
                using: StoreMigrationEngine(), at: primary
            ) else { return XCTFail("fresh store did not reopen on run \(run)") }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let peak = Double(usage.ru_maxrss) / 1_048_576
            samples.append(seconds)
            peaks.append(peak)
            print(String(format: "FEEDRESETTIMING|run|%d|seconds|%.9f|peakRSSMB|%.3f", run, seconds, peak))
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.map { pow($0 - mean, 2) }.reduce(0, +) / Double(samples.count)
        let sd = sqrt(variance)
        print(String(format: "FEEDRESETSTATS|samples|%@|mean|%.9f|populationSD|%.9f|min|%.9f|max|%.9f|peakRSSMaxMB|%.3f", samples.map { String(format: "%.9f", $0) }.joined(separator: ","), mean, sd, samples.min()!, samples.max()!, peaks.max()!))
    }
}
