import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PersonalAudioMetadata: Sendable, Equatable {
    let title: String
    let artist: String?
    let album: String?
    let durationSeconds: Double?
    let artworkJPEG: Data?
    let chapters: [Chapter]
}

enum PersonalAudioMetadataError: Error, Equatable {
    case notPlayableAudio
}

/// Extracts only bounded metadata; audio bytes are never loaded into memory.
struct PersonalAudioMetadataExtractor: Sendable {
    static let maximumEmbeddedArtworkBytes = 8 * 1_048_576
    static let artworkThumbnailPixels = 512

    private let chapterService: ChapterService

    init(chapterService: ChapterService = ChapterService()) {
        self.chapterService = chapterService
    }

    func extract(from fileURL: URL, originalFilename: String) async throws -> PersonalAudioMetadata {
        let asset = AVURLAsset(url: fileURL)
        let playable: Bool
        let audioTracks: [AVAssetTrack]
        do {
            playable = try await asset.load(.isPlayable)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw PersonalAudioMetadataError.notPlayableAudio
        }
        guard playable, !audioTracks.isEmpty else {
            throw PersonalAudioMetadataError.notPlayableAudio
        }

        // Some playable containers (notably raw PCM files) have no common
        // metadata group. Missing tags are a metadata fallback, not an import
        // failure.
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        let title = await stringValue(.commonKeyTitle, in: commonMetadata)
        let artist = await stringValue(.commonKeyArtist, in: commonMetadata)
        let album = await stringValue(.commonKeyAlbumName, in: commonMetadata)
        let duration = try? await asset.load(.duration).seconds
        let durationSeconds = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let artwork = await artworkJPEG(in: commonMetadata)
        let chapters = await chapterService.chapters(
            chapterURL: nil,
            audioURL: fileURL.absoluteString,
            downloadPath: fileURL.path,
            descriptionHTML: nil
        )

        let fallback = URL(fileURLWithPath: originalFilename)
            .deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PersonalAudioMetadata(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty ?? fallback.nonEmpty ?? "Untitled Audio",
            artist: artist?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            album: album?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            durationSeconds: durationSeconds,
            artworkJPEG: artwork,
            chapters: chapters
        )
    }

    private func stringValue(
        _ key: AVMetadataKey,
        in metadata: [AVMetadataItem]
    ) async -> String? {
        guard let item = metadata.first(where: { $0.commonKey == key }) else { return nil }
        return try? await item.load(.stringValue)
    }

    private func artworkJPEG(in metadata: [AVMetadataItem]) async -> Data? {
        guard let item = metadata.first(where: { $0.commonKey == .commonKeyArtwork }),
              let sourceData = try? await item.load(.dataValue),
              !sourceData.isEmpty,
              sourceData.count <= Self.maximumEmbeddedArtworkBytes,
              let imageSource = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.artworkThumbnailPixels,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary
              ) else { return nil }

        let thumbnailData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            thumbnailData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              thumbnailData.length <= Self.maximumEmbeddedArtworkBytes else { return nil }
        return thumbnailData as Data
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
