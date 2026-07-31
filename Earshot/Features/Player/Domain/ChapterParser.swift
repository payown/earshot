import Foundation

/// Pure chapter parsing: Podcasting 2.0 chapter JSON and timestamp lists pulled
/// from an HTML episode description. Mirrors the Flutter `ChapterService`
/// parsing, kept free of networking so it can be unit-tested directly.
enum ChapterParser {

    // MARK: Podcasting 2.0 JSON

    /// Parses a Podcasting 2.0 chapters file. Skips entries flagged `toc: false`
    /// (hidden from the chapter list) and any without a numeric `startTime`.
    static func parsePodcastIndexJSON(_ data: Data) -> [Chapter] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = root["chapters"] as? [[String: Any]]
        else { return [] }

        var chapters: [Chapter] = []
        for item in raw {
            if let toc = item["toc"] as? Bool, toc == false { continue }
            guard let start = (item["startTime"] as? NSNumber)?.doubleValue else { continue }
            let title = (item["title"] as? String) ?? "Chapter \(chapters.count + 1)"
            chapters.append(
                Chapter(index: chapters.count, startTime: start, title: title, imageURL: item["img"] as? String)
            )
        }
        return chapters
    }

    // MARK: Description timestamps

    /// Parses chapters from timestamps embedded in an HTML description, e.g.
    /// "0:00 Introduction" or "Deep dive - 5:30". Returns an empty list when
    /// fewer than two timestamps are found, so incidental times in prose aren't
    /// mistaken for a chapter list.
    static func parseDescriptionChapters(_ html: String?) -> [Chapter] {
        guard let html, !html.isEmpty else { return [] }
        let text = strippingHTML(html)

        var raw: [(start: Double, title: String)] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let match = firstTimestamp(in: trimmed) else { continue }

            // Only treat timestamps at the start or end of a line as chapters.
            let nearStart = match.range.lowerBound <= trimmed.index(trimmed.startIndex, offsetBy: 10, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            let nearEnd = match.range.upperBound >= (trimmed.index(trimmed.endIndex, offsetBy: -10, limitedBy: trimmed.startIndex) ?? trimmed.startIndex)
            guard nearStart || nearEnd else { continue }
            guard let start = parseTimestamp(match.text) else { continue }

            var title = trimmed
            title.replaceSubrange(match.range, with: "")
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—:•·|"))
            raw.append((start, title))
        }

        guard raw.count >= 2 else { return [] }
        raw.sort { $0.start < $1.start }
        return raw.enumerated().map { i, item in
            Chapter(index: i, startTime: item.start, title: item.title.isEmpty ? "Chapter \(i + 1)" : item.title)
        }
    }

    // MARK: Helpers

    /// Parses "M:SS", "MM:SS", "H:MM:SS" into seconds, rejecting out-of-range
    /// minute/second components.
    static func parseTimestamp(_ ts: String) -> Double? {
        let parts = ts.split(separator: ":").map(String.init)
        if parts.count == 2 {
            guard let m = Int(parts[0]), let s = Int(parts[1]), s < 60 else { return nil }
            return Double(m * 60 + s)
        }
        if parts.count == 3 {
            guard let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]),
                  m < 60, s < 60 else { return nil }
            return Double(h * 3600 + m * 60 + s)
        }
        return nil
    }

    private static func firstTimestamp(in line: String) -> (text: String, range: Range<String.Index>)? {
        // M:SS, MM:SS, H:MM:SS, HH:MM:SS, not preceded by a digit or colon.
        let pattern = "(?<![0-9:])\\b(\\d{1,3}:\\d{2}(?::\\d{2})?)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return (String(line[range]), range)
    }

    private static func strippingHTML(_ html: String) -> String {
        var s = html
        // Block-level closers become newlines so adjacent items split onto lines.
        s = s.replacingOccurrences(
            of: "<br\\s*/?>|</p>|</li>|</div>|</h\\d>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#8211;": "–", "&#8212;": "—"]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        s = s.replacingOccurrences(of: "&#\\d+;", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&[a-z]+;", with: "", options: .regularExpression)
        return s
    }
}
