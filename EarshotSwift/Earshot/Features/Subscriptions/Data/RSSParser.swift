import Foundation

struct ParsedEpisode {
    var guid: String
    var title: String
    var audioURL: String
    var description: String?
    var pubDate: Date?
    var durationSeconds: Int?
    var artworkURL: String?
    var episodeNumber: Int?
    var seasonNumber: Int?
    var chapterURL: String?
    var transcriptURL: String?
}

struct ParsedFeed {
    var title: String
    var artworkURL: String?
    var description: String?
    var author: String?
    var websiteURL: String?
    var language: String?
    var category: String?
    var episodes: [ParsedEpisode]
}

/// An `XMLParser`-based RSS reader covering the standard RSS elements plus the
/// iTunes (`itunes:`) and Podcasting 2.0 (`podcast:`) namespaces needed to
/// subscribe to a feed and populate episodes. Namespaces are not processed, so
/// element names arrive as qualified names (e.g. `itunes:duration`).
final class RSSParser: NSObject, XMLParserDelegate {
    // Feed-level
    private var feedTitle = ""
    private var feedImage: String?
    private var feedDescription: String?
    private var feedSummary: String?
    private var feedAuthor: String?
    private var feedLink: String?
    private var feedLanguage: String?
    private var feedCategory: String?

    private var inItem = false
    private var text = ""

    // Item-level
    private var itemTitle = ""
    private var itemAudio = ""
    private var itemGUID = ""
    private var itemDescription = ""
    private var itemSummary = ""
    private var itemPubDate = ""
    private var itemDuration: String = ""
    private var itemImage: String?
    private var itemEpisode: String = ""
    private var itemSeason: String = ""
    private var itemChapterURL: String?
    private var itemTranscriptURL: String?

    private var episodes: [ParsedEpisode] = []

    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    func parse(_ data: Data) -> ParsedFeed? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        return ParsedFeed(
            title: feedTitle.trimmed,
            artworkURL: feedImage,
            description: (feedDescription ?? feedSummary)?.trimmed,
            author: feedAuthor?.trimmed,
            websiteURL: feedLink?.trimmed,
            language: feedLanguage?.trimmed,
            category: feedCategory?.trimmed,
            episodes: episodes
        )
    }

    /// Parses an iTunes duration into seconds. Accepts `HH:MM:SS`, `MM:SS`, or a
    /// plain seconds value. Returns nil for empty/invalid input.
    static func parseDuration(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains(":") {
            let parts = s.split(separator: ":").map { Int($0) ?? -1 }
            guard !parts.contains(-1) else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        return Int(s)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch elementName {
        case "item":
            inItem = true
            itemTitle = ""; itemAudio = ""; itemGUID = ""
            itemDescription = ""; itemSummary = ""; itemPubDate = ""
            itemDuration = ""; itemImage = nil; itemEpisode = ""
            itemSeason = ""; itemChapterURL = nil; itemTranscriptURL = nil
        case "enclosure":
            if let url = attributeDict["url"], inItem { itemAudio = url }
        case "itunes:image":
            if let href = attributeDict["href"] {
                if inItem { itemImage = href } else { feedImage = href }
            }
        case "itunes:category":
            if !inItem, feedCategory == nil, let cat = attributeDict["text"] {
                feedCategory = cat
            }
        case "podcast:chapters":
            if inItem, let url = attributeDict["url"] { itemChapterURL = url }
        case "podcast:transcript":
            if inItem, itemTranscriptURL == nil, let url = attributeDict["url"] {
                itemTranscriptURL = url
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmed
        if inItem {
            switch elementName {
            case "title": itemTitle = value
            case "guid": itemGUID = value
            case "description", "content:encoded":
                if itemDescription.isEmpty { itemDescription = value }
            case "itunes:summary": itemSummary = value
            case "pubDate": itemPubDate = value
            case "itunes:duration": itemDuration = value
            case "itunes:episode": itemEpisode = value
            case "itunes:season": itemSeason = value
            case "item":
                inItem = false
                guard !itemAudio.isEmpty else { return }
                let guid = itemGUID.isEmpty ? itemAudio : itemGUID
                let desc = !itemDescription.isEmpty ? itemDescription
                    : (itemSummary.isEmpty ? nil : itemSummary)
                episodes.append(
                    ParsedEpisode(
                        guid: guid,
                        title: itemTitle.isEmpty ? "Untitled episode" : itemTitle,
                        audioURL: itemAudio,
                        description: desc,
                        pubDate: Self.rfc822.date(from: itemPubDate),
                        durationSeconds: Self.parseDuration(itemDuration),
                        artworkURL: itemImage,
                        episodeNumber: Int(itemEpisode),
                        seasonNumber: Int(itemSeason),
                        chapterURL: itemChapterURL,
                        transcriptURL: itemTranscriptURL
                    )
                )
            default:
                break
            }
        } else {
            switch elementName {
            case "title": if feedTitle.isEmpty { feedTitle = value }
            case "description": if feedDescription == nil { feedDescription = value }
            case "itunes:summary": if feedSummary == nil { feedSummary = value }
            case "itunes:author": if feedAuthor == nil { feedAuthor = value }
            case "link": if feedLink == nil, !value.isEmpty { feedLink = value }
            case "language": if feedLanguage == nil { feedLanguage = value }
            default:
                break
            }
        }
        text = ""
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
