import Foundation

/// OPML import/export for podcast subscriptions. Export builds an OPML 2.0
/// document from podcasts; ``feedURLs(from:)`` extracts `xmlUrl`s from an
/// imported document (used by F10 import).
enum OPMLDocument {

    /// An OPML 2.0 document listing each podcast's feed URL.
    static func export(_ podcasts: [(title: String, feedURL: String)]) -> String {
        let outlines = podcasts.map { podcast in
            let title = escape(podcast.title)
            return "    <outline type=\"rss\" text=\"\(title)\" title=\"\(title)\" xmlUrl=\"\(escape(podcast.feedURL))\"/>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>Earshot Subscriptions</title>
          </head>
          <body>
        \(outlines)
          </body>
        </opml>
        """
    }

    /// Extracts feed URLs (`xmlUrl=`) from an OPML document. Order-preserving and
    /// de-duplicated. Lenient: works on any OPML regardless of nesting.
    static func feedURLs(from opml: String) -> [String] {
        var urls: [String] = []
        var seen = Set<String>()
        // Match xmlUrl="..." (single or double quotes).
        let pattern = #"xmlUrl\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let range = NSRange(opml.startIndex..., in: opml)
        for match in regex.matches(in: opml, range: range) {
            guard let r = Range(match.range(at: 1), in: opml) else { continue }
            let url = unescape(String(opml[r])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty, seen.insert(url).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
