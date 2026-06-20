import Foundation

struct ParsedEpisode {
    var guid: String
    var title: String
    var audioURL: String
    var description: String?
    var pubDate: Date?
}

struct ParsedFeed {
    var title: String
    var artworkURL: String?
    var description: String?
    var episodes: [ParsedEpisode]
}

/// A small XMLParser-based RSS reader: enough to subscribe to a feed and list
/// its episodes for the slice.
final class RSSParser: NSObject, XMLParserDelegate {
    private var feedTitle = ""
    private var feedImage: String?
    private var feedDescription: String?

    private var inItem = false
    private var currentElement = ""
    private var text = ""

    private var itemTitle = ""
    private var itemAudio = ""
    private var itemGUID = ""
    private var itemDescription = ""
    private var itemPubDate = ""

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
            description: feedDescription?.trimmed,
            episodes: episodes
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        text = ""
        switch elementName {
        case "item":
            inItem = true
            itemTitle = ""; itemAudio = ""; itemGUID = ""
            itemDescription = ""; itemPubDate = ""
        case "enclosure":
            if let url = attributeDict["url"], inItem { itemAudio = url }
        case "itunes:image":
            if !inItem, let href = attributeDict["href"] { feedImage = href }
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
            case "pubDate": itemPubDate = value
            case "item":
                inItem = false
                guard !itemAudio.isEmpty else { return }
                let guid = itemGUID.isEmpty ? itemAudio : itemGUID
                episodes.append(
                    ParsedEpisode(
                        guid: guid,
                        title: itemTitle.isEmpty ? "Untitled episode" : itemTitle,
                        audioURL: itemAudio,
                        description: itemDescription.isEmpty ? nil : itemDescription,
                        pubDate: Self.rfc822.date(from: itemPubDate)
                    )
                )
            default:
                break
            }
        } else {
            switch elementName {
            case "title": if feedTitle.isEmpty { feedTitle = value }
            case "description": if feedDescription == nil { feedDescription = value }
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
