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
            <title>Earshot Podcasts</title>
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

    /// A feed group from an imported OPML: feeds nested inside a folder outline
    /// carry that folder's name; top-level feeds are ungrouped (`folder == nil`).
    struct OPMLGroup: Equatable {
        let folder: String?
        let feedURLs: [String]
    }

    /// Parses OPML into folder groups, mapping a nested outline (one with child
    /// outlines and no `xmlUrl`) to a folder. Falls back gracefully on malformed
    /// input. Used by F10 import.
    static func groups(from opml: String) -> [OPMLGroup] {
        guard let data = opml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = OPMLGroupParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.result()
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

/// Builds folder groups from OPML outline nesting. A feed (`xmlUrl`) is assigned
/// to the nearest enclosing named container outline, or ungrouped at top level.
private final class OPMLGroupParser: NSObject, XMLParserDelegate {
    private var folderStack: [String] = []
    private var elementIsFolder: [Bool] = []
    private var collected: [(folder: String?, url: String)] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else { return }
        let url = (attributeDict["xmlUrl"] ?? attributeDict["xmlurl"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let url, !url.isEmpty {
            collected.append((folder: folderStack.last, url: url))
            elementIsFolder.append(false)
        } else {
            folderStack.append(attributeDict["text"] ?? attributeDict["title"] ?? "")
            elementIsFolder.append(true)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName.lowercased() == "outline" else { return }
        if elementIsFolder.popLast() == true, !folderStack.isEmpty {
            folderStack.removeLast()
        }
    }

    func result() -> [OPMLDocument.OPMLGroup] {
        var order: [String?] = []
        var byFolder: [String: [String]] = [:]
        var ungrouped: [String] = []
        var seenUngrouped = false
        for item in collected {
            if let folder = item.folder, !folder.isEmpty {
                if byFolder[folder] == nil { order.append(folder); byFolder[folder] = [] }
                byFolder[folder]?.append(item.url)
            } else {
                if !seenUngrouped { order.append(nil); seenUngrouped = true }
                ungrouped.append(item.url)
            }
        }
        return order.map { folder in
            if let folder {
                return OPMLDocument.OPMLGroup(folder: folder, feedURLs: byFolder[folder] ?? [])
            }
            return OPMLDocument.OPMLGroup(folder: nil, feedURLs: ungrouped)
        }
    }
}
