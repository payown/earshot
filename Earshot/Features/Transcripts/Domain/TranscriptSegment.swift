import Foundation

/// One readable unit of a parsed transcript: an optional speaker label plus the
/// spoken text (#451).
///
/// A segment maps to a caption cue (WebVTT/SRT), a JSON transcript entry, or a
/// paragraph (HTML/plain text). Start time is retained when the source supplies
/// it so Markdown export can preserve useful navigation context. The viewer
/// remains a simple, unsynced scrollable list.
///
/// A plain value type with only `Sendable` stored properties, so it crosses
/// actor boundaries freely.
public struct TranscriptSegment: Equatable, Sendable {
    /// The speaker credited with this text, when the source identified one
    /// (WebVTT `<v Name>`, a `Name:` prefix, or a JSON `speaker` field). `nil`
    /// when the source carries no speaker attribution.
    public let speaker: String?

    /// Cue start in seconds, when supplied by WebVTT, SRT, or transcript JSON.
    public let startSeconds: TimeInterval?

    /// The spoken text, with HTML tags/entities decoded and whitespace
    /// collapsed. Never empty — the parser drops empty segments.
    public let text: String

    public init(speaker: String?, text: String, startSeconds: TimeInterval? = nil) {
        self.speaker = speaker
        self.text = text
        self.startSeconds = startSeconds
    }
}
