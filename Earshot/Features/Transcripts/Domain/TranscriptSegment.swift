import Foundation

/// One readable unit of a parsed transcript: an optional speaker label plus the
/// spoken text (#451).
///
/// A segment maps to a caption cue (WebVTT/SRT), a JSON transcript entry, or a
/// paragraph (HTML/plain text). It is deliberately timing-free — the viewer
/// renders a scrollable, VoiceOver-navigable list, not a synced karaoke view —
/// so start/end times are dropped during parsing.
///
/// A plain value type with only `Sendable` stored properties, so it crosses
/// actor boundaries freely.
public struct TranscriptSegment: Equatable, Sendable {
    /// The speaker credited with this text, when the source identified one
    /// (WebVTT `<v Name>`, a `Name:` prefix, or a JSON `speaker` field). `nil`
    /// when the source carries no speaker attribution.
    public let speaker: String?

    /// The spoken text, with HTML tags/entities decoded and whitespace
    /// collapsed. Never empty — the parser drops empty segments.
    public let text: String

    public init(speaker: String?, text: String) {
        self.speaker = speaker
        self.text = text
    }
}
