import Foundation
import SwiftData

/// User-owned audio copied into Earshot's device-local Personal Audio library.
/// The UUID is its identity; filenames, imported filenames, and media hashes are
/// metadata and never participate in identity or CloudKit projection.
@Model
final class PersonalAudioItem {
    var id: String = UUID().uuidString
    var title: String = ""
    var artist: String?
    var album: String?
    var originalFilename: String = ""
    /// Relative file names within Application Support/PersonalAudio only.
    var mediaFilename: String = ""
    var artworkFilename: String?
    var typeIdentifier: String = ""
    var durationSeconds: Double?
    var byteSize: Int64 = 0
    var importedAt: Date = Date.distantPast
    var positionSeconds: Double = 0
    var isPlayed: Bool = false
    var playedAt: Date?
    var contentHash: String = ""
    var hasEmbeddedChapters: Bool = false

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        originalFilename: String,
        mediaFilename: String,
        artworkFilename: String? = nil,
        typeIdentifier: String,
        durationSeconds: Double? = nil,
        byteSize: Int64,
        importedAt: Date = .now,
        positionSeconds: Double = 0,
        isPlayed: Bool = false,
        playedAt: Date? = nil,
        contentHash: String,
        hasEmbeddedChapters: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.originalFilename = originalFilename
        self.mediaFilename = mediaFilename
        self.artworkFilename = artworkFilename
        self.typeIdentifier = typeIdentifier
        self.durationSeconds = durationSeconds
        self.byteSize = byteSize
        self.importedAt = importedAt
        self.positionSeconds = max(0, positionSeconds)
        self.isPlayed = isPlayed
        self.playedAt = isPlayed ? (playedAt ?? .now) : nil
        self.contentHash = contentHash
        self.hasEmbeddedChapters = hasEmbeddedChapters
    }
}
