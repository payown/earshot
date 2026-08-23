import Foundation
import SwiftData

/// Composite episode identifier `"feedURL|guid"` used wherever an episode must
/// be re-found from a persisted string: a background download task's
/// `taskDescription` and `SettingsKey.lastPlayingEpisodeID` (#576).
///
/// Episode guids are NOT unique across podcasts (bare integers and slugs exist
/// in the wild), so resolving by guid alone can attach a finished download — or
/// restore playback — to the wrong show's episode. The feed URL is unique per
/// podcast (`@Attribute(.unique)`), so the composite is unambiguous. Values
/// written by earlier builds are bare guids; ``parse(_:)`` and
/// ``episode(matching:in:)`` keep resolving those by guid alone.
enum DownloadTaskKey {
    static let separator = "|"

    /// The composite key for an episode. Falls back to the bare guid when the
    /// episode has no podcast (defensive; subscribed episodes always do).
    static func key(feedURL: String?, guid: String) -> String {
        guard let feedURL, !feedURL.isEmpty else { return guid }
        return FeedURLIdentity.canonical(feedURL) + separator + guid
    }

    /// Splits a stored key at the FIRST separator (guids may themselves contain
    /// `"|"`; URLs never do — it's not a legal URL character). A value with no
    /// separator is a legacy bare guid and returns a nil `feedURL` so callers
    /// fall back to guid-only matching.
    static func parse(_ key: String) -> (feedURL: String?, guid: String) {
        guard let range = key.range(of: separator) else { return (nil, key) }
        let feedURL = String(key[..<range.lowerBound])
        let guid = String(key[range.upperBound...])
        guard !feedURL.isEmpty, !guid.isEmpty else { return (nil, key) }
        return (feedURL, guid)
    }

    /// Resolves a stored key (composite or legacy bare guid) to its episode.
    ///
    /// Composite keys require the feed URL to match when more than one episode
    /// shares the guid; a single guid match is accepted even when the feed URL
    /// differs (the podcast's feed URL can change between write and read). As a
    /// last resort the WHOLE key is tried as a guid, covering a legacy guid
    /// that happens to contain the separator. Legacy bare-guid keys resolve by
    /// guid alone, preserving pre-#576 behavior. Synchronous; runs on whatever
    /// context the caller owns (main or a ModelActor's).
    static func episode(matching key: String, in context: ModelContext) -> Episode? {
        let (feedURL, guid) = parse(key)
        let byGUID = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        let candidates = (try? context.fetch(byGUID)) ?? []
        guard let feedURL else { return candidates.first }
        let canonicalFeedURL = FeedURLIdentity.canonical(feedURL)
        if let match = candidates.first(where: {
            $0.podcast.map { FeedURLIdentity.canonical($0.feedURL) == canonicalFeedURL } ?? false
        }) {
            return match
        }
        if candidates.count == 1 { return candidates.first }
        var wholeKeyAsGUID = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == key })
        wholeKeyAsGUID.fetchLimit = 1
        return (try? context.fetch(wholeKeyAsGUID))?.first
    }
}

/// Pure filesystem-path logic for downloaded episode audio. Kept separate from
/// ``DownloadManager`` so the destination naming is unit-testable and so the
/// off-main ``DownloadSessionDelegate`` can compute the same destination the
/// manager would (both key off the episode guid + source extension).
enum DownloadPaths {
    private struct ExistingCandidate<Value> {
        let value: Value
        let modificationDate: Date
        let stableID: String
    }

    /// The `Documents/Downloads` directory, created if missing.
    static func downloadsDirectory() throws -> URL {
        let dir = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        try prepareDownloadsDirectory(at: dir)
        return dir
    }

    /// Creates the re-downloadable media directory and keeps it out of device
    /// and iCloud backups (#710). Applying the resource value on every resolve
    /// also repairs directories created by earlier builds; it is idempotent and
    /// does not alter any downloaded file or playback state.
    static func prepareDownloadsDirectory(at directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }

    /// The stable on-disk destination for an episode's audio inside `directory`,
    /// derived from its `guid` and the source URL's extension. Pure given
    /// `directory`, so it can be exercised in tests without touching Documents.
    static func destination(inDirectory directory: URL, guid: String, sourceURL: URL) -> URL {
        let ext = sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension
        let safeName = guid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return directory.appendingPathComponent(safeName).appendingPathExtension(ext)
    }

    // MARK: Stored-value resolution (#575)

    /// The bare file name for a stored `Episode.downloadPath` value.
    ///
    /// New writes store only the file name, but rows written before #575 hold an
    /// ABSOLUTE container path — and iOS relocates the app container on every
    /// app update, so those absolute paths all go stale. Because the name itself
    /// is deterministic (guid-derived, see ``destination(inDirectory:guid:sourceURL:)``),
    /// the last path component of a legacy value is still the right file name.
    /// Pure, so it's unit-testable. Returns `nil` for nil/empty values.
    static func storedFileName(_ storedValue: String?) -> String? {
        guard let storedValue, !storedValue.isEmpty else { return nil }
        let name = storedValue.contains("/")
            ? (storedValue as NSString).lastPathComponent
            : storedValue
        return name.isEmpty ? nil : name
    }

    /// Resolves a stored `Episode.downloadPath` value against the CURRENT
    /// Downloads directory, tolerating legacy absolute paths. Returns `nil`
    /// when nothing is stored or the directory can't be resolved. Does not
    /// check that the file exists — callers that need that check it on the
    /// returned URL.
    static func resolveLocalURL(storedValue: String?) -> URL? {
        guard let name = storedFileName(storedValue),
              let directory = try? downloadsDirectory() else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// Selects a stored download deterministically, ignoring paths that do not
    /// resolve to a file in the current app container. Modification time is the
    /// only recency signal shared by migrated Episode rows and scalar local-state
    /// rows; persistent ID provides a stable final tie-break.
    static func preferredExistingDownload<Value>(
        from values: [Value],
        storedValue: (Value) -> String?,
        stableID: (Value) -> String
    ) -> Value? {
        values.compactMap { value -> ExistingCandidate<Value>? in
            guard let url = resolveLocalURL(storedValue: storedValue(value)) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            let modificationDate = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            return ExistingCandidate(
                value: value,
                modificationDate: modificationDate,
                stableID: stableID(value)
            )
        }.max {
            if $0.modificationDate != $1.modificationDate {
                return $0.modificationDate < $1.modificationDate
            }
            // `max(by:)` keeps the lexicographically smaller ID preferred.
            return $0.stableID > $1.stableID
        }?.value
    }
}

extension Episode {
    /// The on-disk URL for this episode's downloaded audio, or `nil` when
    /// nothing was downloaded. Always resolved against the CURRENT container
    /// (the stored value is just a file name; iOS moves the container on every
    /// app update, #575), so this — never `downloadPath` directly — is the one
    /// way to reach the local file. Existence is NOT checked here.
    var localAudioURL: URL? {
        DownloadPaths.resolveLocalURL(storedValue: downloadPath)
    }
}
