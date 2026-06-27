import XCTest
import UIKit
@testable import Earshot

/// Tests for the disk-backed artwork cache (#385).
///
/// These avoid real network access: the cache-hit path is exercised by
/// pre-seeding the backing `URLCache` with a stored response, and the directory
/// derivation / clear paths are pure filesystem work.
final class ArtworkCacheTests: XCTestCase {

    // MARK: Directory derivation

    /// The cache directory must live under the app's Caches directory in a
    /// dedicated `artwork` subfolder so the system can evict it under pressure
    /// and `SettingsReset` can find it.
    func test_cacheDirectoryURL_isUnderCachesDirectory() throws {
        let dir = try XCTUnwrap(ArtworkCache.cacheDirectoryURL())
        XCTAssertEqual(dir.lastPathComponent, ArtworkCache.directoryName)

        let caches = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        XCTAssertEqual(dir.deletingLastPathComponent().standardizedFileURL,
                       caches.standardizedFileURL,
                       "Artwork cache must sit directly inside the Caches directory")
    }

    // MARK: Disk-backed capacity

    /// The backing `URLCache` must have a real on-disk capacity — this is what
    /// lets artwork survive a relaunch instead of re-downloading.
    func test_backingURLCache_hasDiskCapacity() {
        let cache = ArtworkCache()
        XCTAssertGreaterThan(cache.urlCache.diskCapacity, 0,
                             "Artwork cache must be disk-backed to survive relaunch")
    }

    // MARK: Cache-hit returns stored data (no network)

    /// When a response is already stored for a URL, `data(for:)` must return the
    /// stored bytes without hitting the network. We seed the cache directly and
    /// assert the round-trip, which models the post-relaunch disk-hit path.
    func test_dataFor_returnsStoredResponseWithoutNetwork() async throws {
        let cache = ArtworkCache()
        let url = try XCTUnwrap(URL(string: "https://example.test/artwork-\(UUID().uuidString).jpg"))
        let payload = Data("seeded-artwork-bytes".utf8)

        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/jpeg"]
        ))
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        cache.urlCache.storeCachedResponse(CachedURLResponse(response: response, data: payload),
                                           for: request)

        let result = await cache.data(for: url)
        XCTAssertEqual(result, payload,
                       "data(for:) should return the stored response without a network call")

        cache.urlCache.removeAllCachedResponses()
    }

    /// `image(for:maxPixelSize:)` should decode a stored image response into a
    /// `UIImage`.
    func test_imageFor_decodesStoredImageData() async throws {
        let cache = ArtworkCache()
        let url = try XCTUnwrap(URL(string: "https://example.test/image-\(UUID().uuidString).png"))

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
        let pngData = try XCTUnwrap(renderer.image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }.pngData())

        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        ))
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        cache.urlCache.storeCachedResponse(CachedURLResponse(response: response, data: pngData),
                                           for: request)

        let image = await cache.image(for: url, maxPixelSize: 56)
        XCTAssertNotNil(image, "image(for:maxPixelSize:) should decode a stored PNG response")

        cache.urlCache.removeAllCachedResponses()
    }

    // MARK: Downsampling (#481)

    /// `downsampledImage(from:maxPixelSize:)` must decode a large source down so
    /// its longest edge is at most `maxPixelSize` pixels — this is what keeps a
    /// full-resolution image from decoding on the main thread during scroll.
    func test_downsampledImage_capsLongestEdgeToMaxPixelSize() throws {
        let sourceData = try Self.makeJPEGData(side: 1000)

        let image = try XCTUnwrap(
            ArtworkCache.downsampledImage(from: sourceData, maxPixelSize: 100),
            "A valid JPEG should produce a downsampled image"
        )

        // The thumbnail is built at scale 1, so point size equals pixel size.
        let longestEdge = max(image.size.width, image.size.height)
        XCTAssertLessThanOrEqual(longestEdge, 100,
                                 "Longest edge must be capped at maxPixelSize, was \(longestEdge)")
        XCTAssertGreaterThan(longestEdge, 0, "A real image must have non-zero size")
    }

    /// A source already smaller than the cap must not be upscaled — the thumbnail
    /// stays at the source size rather than being blown up to `maxPixelSize`.
    func test_downsampledImage_smallSource_isNotUpscaled() throws {
        let sourceData = try Self.makeJPEGData(side: 40)

        let image = try XCTUnwrap(
            ArtworkCache.downsampledImage(from: sourceData, maxPixelSize: 200)
        )

        let longestEdge = max(image.size.width, image.size.height)
        XCTAssertLessThanOrEqual(longestEdge, 40,
                                 "A small source must not be upscaled past its own size")
    }

    /// Non-image bytes must return `nil` (the caller then falls back), not crash.
    func test_downsampledImage_invalidData_returnsNil() {
        let garbage = Data("not-an-image".utf8)
        XCTAssertNil(ArtworkCache.downsampledImage(from: garbage, maxPixelSize: 100),
                     "Undecodable data must return nil so the caller can fall back")
    }

    /// JPEG bytes for a solid `side`×`side` square in *pixels*, used to exercise
    /// downsampling. The renderer scale is pinned to 1 so the encoded pixel
    /// dimensions equal `side` regardless of the test host's Retina scale —
    /// downsampling is measured in pixels, so the source pixel size must be exact.
    private static func makeJPEGData(side: CGFloat) throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    // MARK: Miss returns nil (no crash, no network)

    /// On a true cache miss `data(for:)` must return `nil` without throwing or
    /// crashing. We use an unsupported URL scheme so URLSession fails the request
    /// synchronously at the URL-loading layer — exercising the catch/`nil` path
    /// without any real network access.
    func test_dataFor_unservableURL_returnsNilWithoutCrash() async throws {
        let cache = ArtworkCache()
        // `unsupported://` has no protocol handler, so the load fails immediately
        // with no network traffic; the result must be a graceful nil.
        let url = try XCTUnwrap(URL(string: "unsupported://example.test/missing.jpg"))

        let result = await cache.data(for: url)
        XCTAssertNil(result,
                     "A miss / unservable URL must return nil, not crash or throw")
    }

    /// `image(for:)` must likewise return `nil` (not crash) when the underlying
    /// fetch yields no data.
    func test_imageFor_unservableURL_returnsNil() async throws {
        let cache = ArtworkCache()
        let url = try XCTUnwrap(URL(string: "unsupported://example.test/missing.png"))

        let image = await cache.image(for: url, maxPixelSize: 56)
        XCTAssertNil(image, "image(for:maxPixelSize:) must return nil when no data can be fetched")
    }

    // MARK: Memory-only defensive fallback

    /// When the Caches directory is unavailable the initializer falls back to a
    /// memory-only `URLCache` (`diskCapacity: 0`). This asserts that fallback
    /// configuration still serves a seeded response in-process, proving the
    /// fallback gives a usable cache for the current launch rather than failing.
    func test_memoryOnlyFallbackCache_stillServesSeededResponse() throws {
        // Mirror the init()'s else-branch construction exactly.
        let fallback = URLCache(memoryCapacity: ArtworkCache.memoryCapacity,
                                diskCapacity: 0, directory: nil)
        XCTAssertEqual(fallback.diskCapacity, 0,
                       "Fallback cache must be memory-only (no disk store)")

        let url = try XCTUnwrap(URL(string: "https://example.test/fallback-\(UUID().uuidString).jpg"))
        let payload = Data("fallback-bytes".utf8)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        fallback.storeCachedResponse(
            CachedURLResponse(response: response, data: payload), for: request)

        XCTAssertEqual(fallback.cachedResponse(for: request)?.data, payload,
                       "Memory-only fallback must still serve a stored response in-process")
    }

    // MARK: Clear path

    /// `clear()` (used by SettingsReset) must run against a seeded cache without
    /// error. The disk store evicts asynchronously, so the deterministic proof
    /// that a reset drops artwork is the directory-removal test in
    /// `SettingsStoreTests`; here we only assert the call path is sound.
    func test_clear_runsAgainstSeededCacheWithoutError() throws {
        let cache = ArtworkCache()
        let url = try XCTUnwrap(URL(string: "https://example.test/clear-\(UUID().uuidString).jpg"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        ))
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        cache.urlCache.storeCachedResponse(
            CachedURLResponse(response: response, data: Data("x".utf8)), for: request)
        XCTAssertNotNil(cache.urlCache.cachedResponse(for: request),
                        "Sanity: the response should be stored before clearing")

        cache.clear()
    }
}
