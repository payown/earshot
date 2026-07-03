import Foundation

/// Pure, synchronous transcript parsing (#451): raw text in, `[TranscriptSegment]`
/// out. No I/O, no SwiftData, no networking — so every branch is unit-testable
/// directly and the service layer only has to fetch bytes and pick a format.
///
/// The parser **never throws**: malformed input yields a best-effort array
/// (possibly empty). Empty segments are always dropped. HTML tags and entities
/// in cue/segment text are decoded through ``EpisodeSummary`` so the shared
/// strip logic is used everywhere.
enum TranscriptParser {

    /// Parses `raw` according to `format`. See per-format notes in the private
    /// helpers below. Returns a best-effort list; never throws.
    static func parse(_ raw: String, as format: TranscriptFormat) -> [TranscriptSegment] {
        switch format {
        case .webVTT, .srt:
            // WebVTT and SRT share a structure: cue/timing blocks separated by
            // blank lines. The block extractor ignores the `WEBVTT` header and
            // numeric index lines because neither follows a `-->` timing line.
            return parseCueBased(raw)
        case .json:
            return parseJSON(raw)
        case .html:
            return parseHTML(raw)
        case .plainText:
            return parsePlainText(raw)
        }
    }

    // MARK: - WebVTT / SRT (cue based)

    /// Extracts cue text from a WebVTT or SRT body.
    ///
    /// Algorithm: walk the lines; when a line contains the `-->` timing marker,
    /// the following non-blank lines up to the next blank line are that cue's
    /// text. Everything else (the `WEBVTT` header, cue-number/index lines,
    /// `NOTE`/`STYLE`/`REGION` blocks, timestamp metadata) is skipped because it
    /// does not follow a timing line. Multi-line cue text is merged into one
    /// segment. Speaker attribution and entity/tag decoding are applied per cue.
    private static func parseCueBased(_ raw: String) -> [TranscriptSegment] {
        let lines = normalizedLines(raw)
        var segments: [TranscriptSegment] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard line.contains("-->") else {
                index += 1
                continue
            }

            // Collect the cue text: every non-blank line until the next blank.
            index += 1
            var cueLines: [String] = []
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                cueLines.append(lines[index])
                index += 1
            }

            if let segment = makeCueSegment(from: cueLines) {
                segments.append(segment)
            }
        }

        return segments
    }

    /// Builds a segment from one cue's raw text lines, extracting a speaker and
    /// decoding tags/entities. Returns nil when the cue reduces to empty text.
    private static func makeCueSegment(from cueLines: [String]) -> TranscriptSegment? {
        guard !cueLines.isEmpty else { return nil }
        let merged = cueLines.joined(separator: " ")

        // WebVTT voice span: `<v Speaker>text</v>` (classes allowed, e.g.
        // `<v.loud Bob>`). Capture the name before EpisodeSummary strips the tag.
        var speaker = voiceSpanSpeaker(in: merged)

        // Decode entities and strip all tags (including the <v …> span and inline
        // `<00:00.000>` timestamps) via the shared strip; collapses whitespace.
        let plain = EpisodeSummary.plainText(merged)

        // Fall back to a leading "Speaker: text" label when there was no voice
        // span. Requires a space after the colon so URLs (`https://…`) don't
        // masquerade as speakers.
        var text = plain
        if speaker == nil, let colon = colonSpeaker(in: plain) {
            speaker = colon.speaker
            text = colon.text
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return TranscriptSegment(speaker: normalizedSpeaker(speaker), text: trimmed)
    }

    // MARK: - JSON (Podcasting 2.0 transcript)

    /// Parses a Podcasting 2.0 transcript JSON body of the shape
    /// `{ "segments": [ { "speaker": "…", "startTime": n, "body": "…" }, … ] }`.
    ///
    /// Defensive by design (uses `JSONSerialization`, not `Codable`): a missing
    /// `segments` array, non-object entries, or missing/non-string `body` values
    /// are skipped rather than throwing. `body` is the documented text key;
    /// `text` is accepted as a fallback some producers emit. Consecutive
    /// same-speaker entries are coalesced into readable, length-bounded
    /// paragraphs so word- or phrase-level transcripts don't become thousands of
    /// one-word VoiceOver stops.
    private static func parseJSON(_ raw: String) -> [TranscriptSegment] {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSegments = root["segments"] as? [[String: Any]] else {
            return []
        }

        var segments: [TranscriptSegment] = []
        for entry in rawSegments {
            let body = (entry["body"] as? String) ?? (entry["text"] as? String) ?? ""
            let text = EpisodeSummary.plainText(body)
            guard !text.isEmpty else { continue }
            segments.append(
                TranscriptSegment(speaker: normalizedSpeaker(entry["speaker"] as? String), text: text)
            )
        }

        return coalesceBySpeaker(segments)
    }

    // MARK: - HTML

    /// Splits an HTML transcript into one segment per block-level paragraph via
    /// the shared ``EpisodeSummary/paragraphs(_:)`` strip. No speaker extraction
    /// — HTML transcripts rarely carry structured speaker markup.
    private static func parseHTML(_ raw: String) -> [TranscriptSegment] {
        EpisodeSummary.paragraphs(raw).map { TranscriptSegment(speaker: nil, text: $0) }
    }

    // MARK: - Plain text

    /// Splits a plain-text transcript into paragraphs on blank lines. Intra-
    /// paragraph line breaks and runs of whitespace are collapsed to single
    /// spaces. No speaker extraction.
    private static func parsePlainText(_ raw: String) -> [TranscriptSegment] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // Blank out whitespace-only lines so "a\n \nb" splits like "a\n\nb".
            .replacingOccurrences(of: "(?m)^[ \\t]+$", with: "", options: .regularExpression)
        // Split on blank lines (a paragraph break).
        let blocks = normalized.components(separatedBy: "\n\n")
        var segments: [TranscriptSegment] = []
        for block in blocks {
            let collapsed = block
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !collapsed.isEmpty else { continue }
            segments.append(TranscriptSegment(speaker: nil, text: collapsed))
        }
        return segments
    }

    // MARK: - Helpers

    /// Normalises line endings and returns the lines (empty lines preserved so
    /// blank-line cue boundaries survive).
    private static func normalizedLines(_ raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Extracts the speaker name from a WebVTT voice span (`<v Name>` or a
    /// classed `<v.loud Name>`). Returns nil when there is no voice span.
    private static func voiceSpanSpeaker(in text: String) -> String? {
        // `<v` then optional `.class` tokens, required whitespace, then the name
        // up to `>`.
        let pattern = "<v(?:\\.[^\\s>]+)*\\s+([^>]+)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Extracts a leading `Speaker: text` label from already-plain text.
    ///
    /// Deliberately conservative to avoid mistaking ordinary prose (or a URL)
    /// for a speaker: the label must be ≤ 40 characters, contain no sentence
    /// period, and be **followed by whitespace** after the colon (so `https://…`
    /// — which has no space after its colon — is never treated as a speaker).
    private static func colonSpeaker(in text: String) -> (speaker: String, text: String)? {
        let pattern = "^([^:\\n]{1,40}):\\s+(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 2 else {
            return nil
        }
        let label = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let rest = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject labels that read like a sentence rather than a name.
        guard !label.isEmpty, !rest.isEmpty, !label.contains(".") else { return nil }
        return (label, rest)
    }

    /// Trims a speaker label and maps empty/whitespace-only labels to nil.
    private static func normalizedSpeaker(_ speaker: String?) -> String? {
        guard let trimmed = speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Coalesces consecutive segments that share a speaker into readable
    /// paragraphs, flushing when the speaker changes or the accumulated text
    /// would exceed `maxParagraphLength`. This keeps unpredictable JSON
    /// granularity (word- or phrase-level) from producing an unusable number of
    /// tiny VoiceOver stops, without merging a whole solo episode into one block.
    private static func coalesceBySpeaker(
        _ segments: [TranscriptSegment],
        maxParagraphLength: Int = 320
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            if let last = result.last,
               last.speaker == segment.speaker,
               last.text.count + segment.text.count + 1 <= maxParagraphLength {
                result[result.count - 1] = TranscriptSegment(
                    speaker: last.speaker,
                    text: last.text + " " + segment.text
                )
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
