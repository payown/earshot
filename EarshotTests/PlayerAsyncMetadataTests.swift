import MediaPlayer
import UIKit
import XCTest
@testable import Earshot

@MainActor
private final class MetadataGate<Value: Sendable> {
    private var requests: [CheckedContinuation<Value, Never>] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func load() async -> Value {
        await withCheckedContinuation { continuation in
            requests.append(continuation)
            let ready = startWaiters.filter { $0.0 <= requests.count }
            startWaiters.removeAll { $0.0 <= requests.count }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func complete(_ index: Int, with value: Value) {
        requests[index].resume(returning: value)
    }
}

@MainActor
final class PlayerAsyncMetadataTests: XCTestCase {
    private func episode(_ name: String, guid: String = "shared", artwork: String? = nil) -> Episode {
        let result = Episode(guid: guid, title: name, audioURL: "https://example.com/\(name).mp3")
        result.artworkURL = artwork
        return result
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testChapterRequestsRejectSameGUIDAndRevisitResults() async {
        let gate = MetadataGate<[Chapter]>()
        let player = PlayerService(chapterLoader: { _, _, _, _ in await gate.load() }, artworkLoader: { _ in nil })
        let first = episode("first")
        let second = episode("second")
        let stale = [Chapter(index: 0, startTime: 0, title: "Stale")]
        let current = [Chapter(index: 0, startTime: 0, title: "Current")]

        player.load(first)
        await gate.waitForRequests(1)
        player.load(second)
        await gate.waitForRequests(2)
        gate.complete(0, with: stale)
        await settle()
        XCTAssertEqual(player.chapterCount, 0, "A shared GUID must not authorize an earlier result")
        XCTAssertTrue(player.isLoadingChapters, "An older result must not finish the new lookup")

        player.load(first)
        await gate.waitForRequests(3)
        gate.complete(2, with: current)
        await settle()
        XCTAssertEqual(player.currentChapterTitle, "Current")
        XCTAssertEqual(player.loadedChapterSnapshot, current)
        XCTAssertFalse(player.isLoadingChapters)
        gate.complete(1, with: stale)
        await settle()
        XCTAssertEqual(player.currentChapterTitle, "Current", "An older request must not replace the revisited episode")
        player.stopAndUnload()
    }

    func testPlayerRejectsInvalidChapterTimesAndReindexesSurvivors() {
        let player = PlayerService()
        player.setChapters([
            Chapter(index: 0, startTime: -.infinity, title: "Bad"),
            Chapter(index: 1, startTime: 0.5, title: "First", imageURL: "https://example.com/image"),
            Chapter(index: 2, startTime: .nan, title: "Bad too"),
            Chapter(index: 3, startTime: 61.75, title: "Second"),
            Chapter(index: 4, startTime: Chapter.maximumStartTimeExclusive, title: "Huge")
        ])
        XCTAssertEqual(player.chapterCount, 2)
        XCTAssertEqual(player.loadedChapterSnapshot.map(\.startTime), [0.5, 61.75])
        XCTAssertEqual(player.loadedChapterSnapshot.map(\.index), [0, 1])
        XCTAssertEqual(player.loadedChapterSnapshot.first?.imageURL, "https://example.com/image")
    }

    func testChapterResultAfterStopIsDiscarded() async {
        let gate = MetadataGate<[Chapter]>()
        let player = PlayerService(chapterLoader: { _, _, _, _ in await gate.load() }, artworkLoader: { _ in nil })
        player.load(episode("first"))
        await gate.waitForRequests(1)
        player.stopAndUnload()
        gate.complete(0, with: [Chapter(index: 0, startTime: 0, title: "Stale")])
        await settle()
        XCTAssertEqual(player.chapterCount, 0)
        XCTAssertNil(player.currentChapterTitle)
        XCTAssertFalse(player.isLoadingChapters)
    }

    func testDelayedPersonalAudioChaptersAreSharedAndSwitchingIgnoresOldResult() async {
        let gate = MetadataGate<[Chapter]>()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = PersonalAudioStorage(rootURL: root)
        let item = PersonalAudioItem(
            id: "personal", title: "Personal", originalFilename: "personal.mp3",
            mediaFilename: "personal.mp3", typeIdentifier: "public.audio",
            byteSize: 0, contentHash: "hash"
        )
        let player = PlayerService(personalAudioStorage: storage, chapterLoader: { _, _, _, _ in await gate.load() }, artworkLoader: { _ in nil })
        let personal = [Chapter(index: 0, startTime: 0, title: "Personal chapter")]
        let podcast = [Chapter(index: 0, startTime: 0, title: "Podcast chapter")]

        player.load(item)
        await gate.waitForRequests(1)
        XCTAssertTrue(player.isLoadingChapters)
        XCTAssertTrue(player.loadedChapterSnapshot.isEmpty)
        gate.complete(0, with: personal)
        await settle()
        XCTAssertFalse(player.isLoadingChapters)
        XCTAssertEqual(player.loadedChapterSnapshot, personal, "The sheet and engine use the same completed result")

        player.load(item)
        await gate.waitForRequests(2)
        player.load(episode("podcast"))
        await gate.waitForRequests(3)
        gate.complete(1, with: personal)
        await settle()
        XCTAssertTrue(player.isLoadingChapters)
        XCTAssertTrue(player.loadedChapterSnapshot.isEmpty)
        gate.complete(2, with: podcast)
        await settle()
        XCTAssertFalse(player.isLoadingChapters)
        XCTAssertEqual(player.loadedChapterSnapshot, podcast)
        player.stopAndUnload()
    }

    func testArtworkResultsCannotReplaceNewerArtworkOrReappearAfterStop() async {
        let gate = MetadataGate<Data?>()
        let player = PlayerService(chapterLoader: { _, _, _, _ in [] }, artworkLoader: { _ in
            guard let data = await gate.load() else { return nil }
            return UIImage(data: data)
        })
        let first = episode("first", artwork: "https://example.com/first.png")
        let second = episode("second", artwork: "https://example.com/second.png")
        let red = image(.red)
        let blue = image(.blue)
        XCTAssertNotEqual(pixel(red), pixel(blue), "The fixture colors must be distinguishable")

        player.load(first)
        await gate.waitForRequests(1)
        player.load(second)
        await gate.waitForRequests(2)
        player.load(first)
        await gate.waitForRequests(3)
        gate.complete(2, with: blue.pngData())
        await settle()
        XCTAssertEqual(currentArtwork().flatMap(pixel), pixel(blue))
        gate.complete(0, with: red.pngData())
        await settle()
        XCTAssertEqual(currentArtwork().flatMap(pixel), pixel(blue), "A previous visit to the same URL is stale")
        player.stopAndUnload()
        gate.complete(1, with: red.pngData())
        await settle()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func currentArtwork() -> UIImage? {
        let artwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        return artwork?.image(at: CGSize(width: 2, height: 2))
    }

    /// Inspect rendered pixels rather than comparing PNG encodings: decoding and
    /// re-encoding an image can change its PNG metadata without changing the image.
    private func pixel(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return rendered ? bytes : nil
    }
}
