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
        return document(body: outlines)
    }

    /// A single podcast feed in the export tree. Value type so export stays free
    /// of SwiftData; the data layer maps its `Podcast`s onto these.
    struct OPMLFeed: Equatable {
        let title: String
        let feedURL: String
    }

    /// A folder in the export tree: its display name, the feeds filed **directly**
    /// in it (not in a subfolder), and its nested subfolders. Recursive so an
    /// arbitrarily deep folder hierarchy round-trips through nested `<outline>`
    /// groups. New in folders phase 3 (#764).
    struct OPMLFolderNode: Equatable {
        let name: String
        let feeds: [OPMLFeed]
        let children: [OPMLFolderNode]
    }

    /// An OPML 2.0 document that preserves the user's folder hierarchy: each folder
    /// becomes a group `<outline text="Folder">` containing its own feeds and then
    /// its subfolders (recursively), and the `unfiled` podcasts are written as a
    /// flat list at the top level. This is the export the app wires to "Export
    /// podcasts (OPML)" so a user's structure round-trips (import → export → import
    /// is stable). Empty folders emit an empty group and simply drop out on
    /// re-import, since ``groups(from:)`` only surfaces folders that hold feeds.
    static func export(folders: [OPMLFolderNode], unfiled: [OPMLFeed]) -> String {
        var lines: [String] = []
        for folder in folders {
            lines.append(contentsOf: outlineLines(for: folder, depth: 1))
        }
        for feed in unfiled {
            lines.append(feedLine(for: feed, depth: 1))
        }
        return document(body: lines.joined(separator: "\n"))
    }

    /// Wraps a pre-rendered `<body>` in the shared OPML 2.0 envelope so the flat and
    /// nested exports produce byte-identical heads and framing.
    private static func document(body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>Earshot Podcasts</title>
          </head>
          <body>
        \(body)
          </body>
        </opml>
        """
    }

    /// Renders a folder group and everything nested inside it. `depth` is measured
    /// in two-space indent steps below `<body>` (top-level folders sit at depth 1,
    /// i.e. four spaces, matching the flat export's outline indentation).
    private static func outlineLines(for folder: OPMLFolderNode, depth: Int) -> [String] {
        let pad = String(repeating: "  ", count: depth + 1)
        let name = escape(folder.name)
        var lines = ["\(pad)<outline text=\"\(name)\" title=\"\(name)\">"]
        for feed in folder.feeds {
            lines.append(feedLine(for: feed, depth: depth + 1))
        }
        for child in folder.children {
            lines.append(contentsOf: outlineLines(for: child, depth: depth + 1))
        }
        lines.append("\(pad)</outline>")
        return lines
    }

    /// Renders one feed outline at the given `depth`.
    private static func feedLine(for feed: OPMLFeed, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth + 1)
        let title = escape(feed.title)
        return "\(pad)<outline type=\"rss\" text=\"\(title)\" title=\"\(title)\" xmlUrl=\"\(escape(feed.feedURL))\"/>"
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
