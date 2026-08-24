import Foundation

/// Which source-provided segment metadata is included in a Markdown export
/// (#900). Raw values are stable device-local persistence; titles are the exact
/// option names promised to VoiceOver users.
enum TranscriptExportMetadata: String, CaseIterable, Identifiable, Sendable {
    case speakersOnly = "speakers_only"
    case timestampsOnly = "timestamps_only"
    case speakersAndTimestamps = "speakers_and_timestamps"

    var id: Self { self }

    var title: String {
        switch self {
        case .speakersOnly: return "Speakers only"
        case .timestampsOnly: return "Timestamps only"
        case .speakersAndTimestamps: return "Speakers and timestamps"
        }
    }

    var includesSpeakers: Bool { self != .timestampsOnly }
    var includesTimestamps: Bool { self != .speakersOnly }
}

/// Builds and writes the normalized Markdown transcript shared by the viewer
/// and episode Quick Actions (#717). The pure formatter is separately testable;
/// file creation is confined to a unique temporary directory for the system
/// share/save sheet.
enum TranscriptMarkdownExporter {
    static func markdown(
        podcastTitle: String?,
        episodeTitle: String,
        publicationDate: Date?,
        segments: [TranscriptSegment],
        metadata: TranscriptExportMetadata
    ) -> String {
        var lines = ["# \(singleLine(episodeTitle, fallback: "Episode"))", ""]
        if let podcastTitle, !singleLine(podcastTitle, fallback: "").isEmpty {
            lines.append("**Podcast:** \(singleLine(podcastTitle, fallback: ""))")
        }
        if let publicationDate {
            lines.append("**Published:** \(dateString(publicationDate))")
        }
        if lines.last != "" { lines.append("") }
        lines.append("## Transcript")
        lines.append("")

        for segment in segments {
            var prefix = ""
            if metadata.includesTimestamps, let start = segment.startSeconds {
                prefix += "[\(timestamp(start))] "
            }
            if metadata.includesSpeakers, let speaker = segment.speaker, !speaker.isEmpty {
                prefix += "**\(escapeEmphasis(singleLine(speaker, fallback: "Speaker"))):** "
            }
            lines.append(prefix + segment.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func fileName(podcastTitle: String?, episodeTitle: String) -> String {
        let podcast = safeComponent(podcastTitle ?? "")
        let episode = safeComponent(episodeTitle)
        let base: String
        if podcast.isEmpty, episode.isEmpty {
            base = "Episode transcript"
        } else if podcast.isEmpty {
            base = episode
        } else if episode.isEmpty {
            base = podcast
        } else {
            base = "\(podcast) - \(episode)"
        }
        return "\(base).md"
    }

    static func write(
        podcastTitle: String?,
        episodeTitle: String,
        publicationDate: Date?,
        segments: [TranscriptSegment],
        metadata: TranscriptExportMetadata,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appending(path: "Earshot-Transcript-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(
            path: fileName(podcastTitle: podcastTitle, episodeTitle: episodeTitle),
            directoryHint: .notDirectory
        )
        try Data(markdown(
            podcastTitle: podcastTitle,
            episodeTitle: episodeTitle,
            publicationDate: publicationDate,
            segments: segments,
            metadata: metadata
        ).utf8).write(to: url, options: .atomic)
        return url
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remaining = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%02d:%02d", minutes, remaining)
    }

    private static func dateString(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func singleLine(_ value: String, fallback: String) -> String {
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? fallback : collapsed
    }

    private static func safeComponent(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        let replaced = String(value.unicodeScalars.map { illegal.contains($0) ? " " : Character($0) })
        return singleLine(replaced, fallback: "")
    }

    private static func escapeEmphasis(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

/// Testable viewer entry point. Keeping this adapter distinct from the Quick
/// Action adapter proves both user-facing paths forward the saved preference.
enum TranscriptViewerExport {
    static func write(
        podcastTitle: String?,
        episodeTitle: String,
        publicationDate: Date?,
        segments: [TranscriptSegment],
        metadata: TranscriptExportMetadata,
        fileManager: FileManager = .default
    ) throws -> URL {
        try TranscriptMarkdownExporter.write(
            podcastTitle: podcastTitle,
            episodeTitle: episodeTitle,
            publicationDate: publicationDate,
            segments: segments,
            metadata: metadata,
            fileManager: fileManager
        )
    }
}

/// Testable episode Quick Action entry point. Transcript loading and its existing
/// announcements remain in the presentation modifier; normalized file creation
/// is kept pure and shared with the viewer.
enum EpisodeQuickActionTranscriptExport {
    static func write(
        podcastTitle: String?,
        episodeTitle: String,
        publicationDate: Date?,
        segments: [TranscriptSegment],
        metadata: TranscriptExportMetadata,
        fileManager: FileManager = .default
    ) throws -> URL {
        try TranscriptMarkdownExporter.write(
            podcastTitle: podcastTitle,
            episodeTitle: episodeTitle,
            publicationDate: publicationDate,
            segments: segments,
            metadata: metadata,
            fileManager: fileManager
        )
    }
}
