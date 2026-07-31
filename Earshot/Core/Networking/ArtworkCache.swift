import Foundation
import ImageIO
import UIKit

/// Disk-backed cache for podcast artwork shared by the UI (``PodcastArtwork``)
/// and the lock-screen / Control Center path (``PlayerService``).
///
/// `AsyncImage` and `URLCache.shared` keep artwork only for the lifetime of the
/// process (and the system cache is small and shared with every other request),
/// so artwork re-downloaded on every cold launch. This cache wires a dedicated
/// ``URLSession`` to its own ``URLCache`` with a real on-disk capacity rooted in
/// the Caches directory, so a previously fetched image is served from disk after
/// a relaunch instead of hitting the network again.
///
/// Concurrency: `URLCache` and `URLSession` are both thread-safe, and the only
/// stored properties are immutable references to them, so the type is a plain
/// `Sendable` `final class`. The `UIImage`/`Data` it returns cross back to the
/// caller's actor; callers that touch the main actor (the SwiftUI loader) hop
/// there themselves after `await`.
final class ArtworkCache: Sendable {
    /// Shared instance used by both the artwork UI and the now-playing path so
    /// they read and write one disk cache (the #378 reuse requirement).
    static let shared = ArtworkCache()

    /// In-memory capacity of the backing ``URLCache``. A small RAM fast-path on
    /// top of the disk store; the disk capacity is what survives relaunch.
    static let memoryCapacity = 16 * 1024 * 1024   // 16 MB
    /// On-disk capacity of the backing ``URLCache``. The system may evict under
    /// storage pressure, which is acceptable for re-fetchable artwork.
    static let diskCapacity = 200 * 1024 * 1024    // 200 MB

    /// Subdirectory name under the Caches directory that holds the URLCache.
    static let directoryName = "artwork"

    /// Longest-edge pixel cap for the lock-screen / Control Center artwork. The
    /// Now Playing art tops out around the device's screen width, so 1024px is
    /// ample while still avoiding a full-resolution (often 3000px) decode. (#481)
    static let nowPlayingMaxPixelSize: CGFloat = 1024

    let urlCache: URLCache
    private let session: URLSession

    /// Builds the cache. Falls back to a memory-only ``URLCache`` if the Caches
    /// directory can't be located, so callers never crash and still get an
    /// in-process cache for the current launch.
    ///
    /// `session` is a test seam only. In production it is nil and a real
    /// disk-cache-backed session is built here (unchanged behavior). Tests inject a
    /// ``MockURLProtocol`` session so `data(for:)`'s miss path never reaches the
    /// real network — otherwise a cache miss fetched a reserved `example.test` host
    /// and intermittently failed with `-1003` (a shared-cache eviction race between
    /// parallel tests). The injected session's own configuration is used as-is.
    init(session: URLSession? = nil) {
        let directory = Self.cacheDirectoryURL()
        let cache: URLCache
        if let directory {
            // Best effort: URLCache creates the directory lazily, but creating it
            // up front lets SettingsReset find and remove it deterministically.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cache = URLCache(memoryCapacity: Self.memoryCapacity,
                             diskCapacity: Self.diskCapacity,
                             directory: directory)
        } else {
            AppLog.networking.error("Artwork cache directory unavailable; using memory-only cache")
            cache = URLCache(memoryCapacity: Self.memoryCapacity, diskCapacity: 0, directory: nil)
        }
        self.urlCache = cache

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.urlCache = cache
            // Serve cached data when present so a relaunch reads from disk instead
            // of re-downloading; only reach the network on a true miss.
            config.requestCachePolicy = .returnCacheDataElseLoad
            self.session = URLSession(configuration: config)
        }
    }

    /// Location of the artwork cache directory inside the app's Caches directory,
    /// or `nil` when the Caches directory can't be resolved.
    static func cacheDirectoryURL() -> URL? {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Raw image data for `url`, served from the disk cache when available and
    /// fetched (then cached) otherwise. Returns `nil` on any failure rather than
    /// throwing — artwork is decorative, so callers fall back to a placeholder.
    func data(for url: URL) async -> Data? {
        // Artwork is a non-media URLSession fetch, so upgrade http→https under the
        // media-only ATS policy (#387). HTTP-only hosts simply fall back to the
        // placeholder (this method returns nil on failure).
        let url = SecureURL.upgradedForNonMedia(url)
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)

        // Fast path: a stored response (memory or disk) avoids the network and,
        // critically, survives relaunch because the URLCache is disk-backed.
        if let cached = urlCache.cachedResponse(for: request) {
            return cached.data
        }

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                AppLog.networking.error("Artwork HTTP \(http.statusCode, privacy: .public) for \(url.absoluteString, privacy: .public)")
                return nil
            }
            return data
        } catch {
            AppLog.networking.error("Artwork fetch failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Decoded artwork image for `url`, downsampled so its longest edge is at most
    /// `maxPixelSize` pixels, or `nil` if it can't be fetched/decoded.
    ///
    /// Callers pass the target draw size in pixels (points × display scale). The
    /// image is decoded once, here, off the main actor — this method is a
    /// `nonisolated async` member of a `Sendable` type, so its body runs on the
    /// cooperative pool rather than the caller's actor — and returned already
    /// decoded at draw size, so nothing decodes the full-resolution source on the
    /// main thread at draw time during scroll. (#481)
    func image(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        guard let data = await data(for: url) else { return nil }
        if let downsampled = Self.downsampledImage(from: data, maxPixelSize: maxPixelSize) {
            return downsampled
        }
        // ImageIO couldn't read this source (an unusual/unsupported container).
        // Fall back to a direct decode so we still show artwork; this path is rare
        // and not on the hot scroll path.
        guard let image = UIImage(data: data) else {
            AppLog.networking.error("Artwork data for \(url.absoluteString, privacy: .public) could not be decoded")
            return nil
        }
        return image
    }

    /// Decodes `data` into a `UIImage` whose longest edge is at most
    /// `maxPixelSize` pixels, forcing the decode immediately so the returned image
    /// carries no deferred main-thread decode. Returns `nil` if ImageIO can't
    /// create a thumbnail from the source.
    ///
    /// Uses `CGImageSourceCreateThumbnailAtIndex`, which decodes straight to the
    /// downsampled size instead of decoding the full image and scaling after.
    /// `kCGImageSourceShouldCacheImmediately` performs the decode now (off the main
    /// thread, since callers `await` this from a background context) rather than
    /// lazily at first draw.
    static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        // Scale 1: the thumbnail is already sized in pixels, so its point size
        // equals its pixel size and the SwiftUI frame controls the layout size.
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Drops every cached artwork response from memory and disk. Used by the
    /// Settings "Reset local data" action so the artwork cache is cleared too.
    func clear() {
        urlCache.removeAllCachedResponses()
    }
}
