import Foundation
import os

struct ParsedEpisode: Sendable {
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
    /// Declared enclosure size from RSS `length` or an Atom enclosure link.
    /// Feed-only metadata used to recognize a publisher replacing media at the
    /// same URL; it is deliberately not persisted on the synced Episode model.
    var enclosureByteLength: Int64? = nil
    /// `itunes:episodeType` — "full", "trailer", or "bonus" (normalized
    /// lowercase); nil when absent or unrecognized. Parse-level only for now:
    /// persisting it on `Episode` needs a SwiftData schema change, deferred to
    /// the next schema window (#384). Defaulted so memberwise call sites keep
    /// compiling.
    var episodeType: String? = nil
}

struct ParsedFeed: Sendable {
    var title: String
    var artworkURL: String?
    var description: String?
    var author: String?
    var websiteURL: String?
    var language: String?
    var category: String?
    var episodes: [ParsedEpisode]
    /// Channel-level `itunes:explicit` — true for "yes"/"true", false for
    /// "no"/"false"/"clean", nil when absent or unrecognized. Parse-level only
    /// for now: persisting it on `Podcast` needs a SwiftData schema change,
    /// deferred to the next schema window (#384). Useful offline regardless
    /// (e.g. deriving the App Store age-rating answer from a feed check).
    var explicit: Bool? = nil
}

/// An `XMLParser`-based RSS reader covering the standard RSS elements plus the
/// iTunes (`itunes:`) and Podcasting 2.0 (`podcast:`) namespaces needed to
/// subscribe to a feed and populate episodes. Namespaces are not processed, so
/// element names arrive as qualified names (e.g. `itunes:duration`).
final class RSSParser: NSObject, XMLParserDelegate {
    /// Directory search needs channel metadata but no episode catalog. In that
    /// mode the parser intentionally aborts at the first item/entry, after the
    /// channel fields that feeds conventionally place before their episodes.
    private var stopsBeforeEpisodes = false
    private var stoppedBeforeEpisodes = false
    // Feed-level
    private var feedTitle = ""
    private var feedImage: String?
    /// Standard RSS `<image><url>` channel art. Kept separate from
    /// ``feedImage`` (itunes:image / Atom logo/icon) so it can act as a
    /// lower-priority fallback regardless of element order in the feed.
    private var channelImageURL: String?
    private var feedDescription: String?
    private var feedSummary: String?
    private var feedAuthor: String?
    private var feedLink: String?
    private var feedLanguage: String?
    private var feedCategory: String?
    private var feedExplicit: Bool?

    private var inItem = false
    /// True while inside a channel-level RSS `<image>` block, whose child
    /// `<url>` is the artwork and whose `<title>`/`<link>` children must not
    /// pollute the feed's own title/link.
    private var inChannelImage = false
    private var text = ""

    // Item-level
    private var itemTitle = ""
    private var itemAudio = ""
    private var itemEnclosureByteLength: Int64?
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
    /// Higher values represent transcript containers that preserve timing as
    /// structured metadata instead of visible prose. Podcast feeds may publish
    /// several representations for one episode; keep the best one regardless
    /// of element order.
    private var itemTranscriptPreference = Int.min
    private var itemEpisodeType: String = ""

    private var episodes: [ParsedEpisode] = []

    /// RFC822 / RSS pubDate formats, tried in order. Real-world feeds vary: some
    /// use named zones (`GMT`, `EST`) instead of numeric offsets, some omit the
    /// weekday, some drop seconds, some drop the leading zero on the day. A
    /// single rigid format silently dropped all of these, stranding episodes in
    /// the inbox high-water-mark logic (review P1-3).
    private static let rfc822Formats: [String] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm Z",
        "EEE, dd MMM yyyy HH:mm zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss zzz",
    ]

    /// Foundation formatters are mutable reference types. Feed refreshes may
    /// parse concurrently, so keep the reusable instances behind one lock.
    /// `@unchecked Sendable` is safe only because every access to these mutable
    /// Foundation formatter objects occurs inside `dateFormatters.withLock`.
    private struct DateFormatters: @unchecked Sendable {
        let rfc822: [DateFormatter] = rfc822Formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
        let iso8601: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
        let iso8601Fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
    }

    private static let dateFormatters = OSAllocatedUnfairLock(initialState: DateFormatters())

    /// Parses a feed date string, trying the RFC822 variants then ISO8601.
    /// Returns nil only when no known format matches.
    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return dateFormatters.withLock { formatters in
            for formatter in formatters.rfc822 {
                if let date = formatter.date(from: s) { return date }
            }
            if let date = formatters.iso8601Fractional.date(from: s) { return date }
            if let date = formatters.iso8601.date(from: s) { return date }
            return nil
        }
    }

    func parse(_ data: Data) -> ParsedFeed? {
        parse(data, stopsBeforeEpisodes: false)
    }

    /// Parses channel-level fields without constructing any ``ParsedEpisode``
    /// values. This is the bounded path for directory VoiceOver descriptions.
    func parseChannelMetadata(_ data: Data) -> ParsedFeed? {
        parse(data, stopsBeforeEpisodes: true)
    }

    private func parse(_ data: Data, stopsBeforeEpisodes: Bool) -> ParsedFeed? {
        self.stopsBeforeEpisodes = stopsBeforeEpisodes
        stoppedBeforeEpisodes = false
        let parser = XMLParser(data: data)
        parser.delegate = self
        let succeeded = parser.parse()
        var title = feedTitle.trimmed
        if !succeeded && !stoppedBeforeEpisodes {
            // Malformed XML somewhere in the document. Everything delegate
            // callbacks accumulated before the abort point is still good, so
            // return a partial feed instead of discarding it all — a broken
            // feed used to subscribe with zero episodes, silently (#384).
            // `episodes` can never hold a half-parsed item: `finishItem()`
            // only runs on an item's closing tag, so an item in progress at
            // the failure point is simply dropped.
            let reason = parser.parserError?.localizedDescription ?? "unknown XML error"
            guard !episodes.isEmpty || !title.isEmpty else {
                AppLog.networking.error(
                    """
                    Feed parse failed with nothing salvageable at line \
                    \(parser.lineNumber), column \(parser.columnNumber): \
                    \(reason, privacy: .public)
                    """
                )
                return nil
            }
            AppLog.networking.error(
                """
                Feed parse failed at line \(parser.lineNumber), column \
                \(parser.columnNumber) (\(reason, privacy: .public)); returning \
                partial feed with \(self.episodes.count) salvaged episode(s)
                """
            )
            if title.isEmpty { title = "Untitled podcast" }
        }
        return ParsedFeed(
            title: title,
            // itunes:image (or Atom logo/icon) wins; the standard RSS
            // <image><url> channel art is the fallback.
            artworkURL: feedImage ?? channelImageURL,
            description: (feedDescription ?? feedSummary)?.trimmed,
            author: feedAuthor?.trimmed,
            websiteURL: feedLink?.trimmed,
            language: feedLanguage?.trimmed,
            category: feedCategory?.trimmed,
            episodes: episodes,
            explicit: feedExplicit
        )
    }

    /// Parses an iTunes duration into seconds. Accepts `HH:MM:SS`, `MM:SS`, or a
    /// plain seconds value. Returns nil for empty/invalid input.
    static func parseDuration(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains(":") {
            let parts = s.split(separator: ":").map { Int($0) }
            // At most HH:MM:SS; more segments is not a duration.
            guard (1...3).contains(parts.count) else { return nil }
            var total = 0
            for part in parts {
                guard let part, part >= 0 else { return nil }
                // Overflow-safe accumulation: a hostile feed can carry values
                // like "999999999999999999:00:00" that trap in the naive
                // `$0 * 60 + $1` reduce (readiness-audit P2-11).
                let (scaled, mulOverflow) = total.multipliedReportingOverflow(by: 60)
                let (sum, addOverflow) = scaled.addingReportingOverflow(part)
                guard !mulOverflow, !addOverflow else { return nil }
                total = sum
            }
            return total
        }
        guard let seconds = Int(s), seconds >= 0 else { return nil }
        return seconds
    }

    /// Maps an `itunes:explicit` value to a tri-state flag. Apple documents
    /// "true"/"false", but real feeds still carry the legacy "yes"/"no"/"clean"
    /// values. Unrecognized input is nil (unknown), never a guess.
    static func parseExplicit(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true": return true
        case "no", "false", "clean": return false
        default: return nil
        }
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
        case "item", "entry":
            if stopsBeforeEpisodes {
                stoppedBeforeEpisodes = true
                parser.abortParsing()
                return
            }
            inItem = true
            itemTitle = ""; itemAudio = ""; itemGUID = ""
            itemEnclosureByteLength = nil
            itemDescription = ""; itemSummary = ""; itemPubDate = ""
            itemDuration = ""; itemImage = nil; itemEpisode = ""
            itemSeason = ""; itemChapterURL = nil; itemTranscriptURL = nil
            itemTranscriptPreference = Int.min
            itemEpisodeType = ""
        case "image":
            if !inItem { inChannelImage = true }
        case "enclosure":
            if let url = attributeDict["url"], inItem {
                itemAudio = url
                itemEnclosureByteLength = Self.parseEnclosureByteLength(
                    attributeDict["length"]
                )
            }
        case "link":
            // Atom links carry their target in attributes (RSS <link> has text
            // content, handled at didEndElement). Inside an entry, the audio is
            // the rel="enclosure" link; at feed level, rel="alternate" (or no
            // rel) is the website.
            if let href = attributeDict["href"] {
                let rel = attributeDict["rel"]
                if inItem {
                    if rel == "enclosure", itemAudio.isEmpty {
                        itemAudio = href
                        itemEnclosureByteLength = Self.parseEnclosureByteLength(
                            attributeDict["length"]
                        )
                    }
                } else if feedLink == nil, rel == nil || rel == "alternate" {
                    feedLink = href
                }
            }
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
            if inItem, let url = attributeDict["url"] {
                let preference = Self.transcriptPreference(
                    urlString: url,
                    mimeType: attributeDict["type"]
                )
                guard itemTranscriptURL == nil || preference > itemTranscriptPreference else {
                    break
                }
                itemTranscriptURL = url
                itemTranscriptPreference = preference
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
            // Atom entries identify themselves with <id>; let an RSS <guid> win
            // if both are somehow present.
            case "id": if itemGUID.isEmpty { itemGUID = value }
            case "description", "content:encoded", "content":
                if itemDescription.isEmpty { itemDescription = value }
            case "itunes:summary": itemSummary = value
            // Atom <summary> is the short form; treat it like itunes:summary.
            case "summary": if itemSummary.isEmpty { itemSummary = value }
            case "pubDate": itemPubDate = value
            // Atom dates: prefer <published>, fall back to <updated>.
            case "published": itemPubDate = value
            case "updated": if itemPubDate.isEmpty { itemPubDate = value }
            case "itunes:duration": itemDuration = value
            case "itunes:episode": itemEpisode = value
            case "itunes:season": itemSeason = value
            case "itunes:episodeType": itemEpisodeType = value
            case "item", "entry":
                finishItem()
            default:
                break
            }
        } else {
            switch elementName {
            // <image> has its own <title>/<link> children; don't let them
            // shadow the channel's title/link when <image> comes first.
            case "title": if feedTitle.isEmpty, !inChannelImage { feedTitle = value }
            case "description": if feedDescription == nil { feedDescription = value }
            // Atom feed-level description / image / author.
            case "subtitle": if feedDescription == nil { feedDescription = value }
            case "itunes:summary": if feedSummary == nil { feedSummary = value }
            case "itunes:author": if feedAuthor == nil { feedAuthor = value }
            case "name": if feedAuthor == nil { feedAuthor = value }
            case "logo", "icon": if feedImage == nil, !value.isEmpty { feedImage = value }
            case "link": if feedLink == nil, !inChannelImage, !value.isEmpty { feedLink = value }
            case "language": if feedLanguage == nil { feedLanguage = value }
            // Standard RSS channel art: <image><url>…</url></image>.
            case "url": if inChannelImage, channelImageURL == nil, !value.isEmpty { channelImageURL = value }
            case "image": inChannelImage = false
            case "itunes:explicit": if feedExplicit == nil { feedExplicit = Self.parseExplicit(value) }
            default:
                break
            }
        }
        text = ""
    }

    /// Finalizes the in-progress item/entry and appends a `ParsedEpisode`.
    /// Shared by RSS `<item>` and Atom `<entry>`; entries with no audio
    /// enclosure (e.g. plain blog posts in a mixed Atom feed) are skipped.
    private func finishItem() {
        inItem = false
        guard !itemAudio.isEmpty else { return }
        let guid = itemGUID.isEmpty ? itemAudio : itemGUID
        let desc = !itemDescription.isEmpty ? itemDescription
            : (itemSummary.isEmpty ? nil : itemSummary)
        // Only the three values Apple defines; anything else is noise.
        let episodeType = itemEpisodeType.lowercased()
        let validEpisodeType = ["full", "trailer", "bonus"].contains(episodeType)
            ? episodeType : nil
        episodes.append(
            ParsedEpisode(
                guid: guid,
                title: itemTitle.isEmpty ? "Untitled episode" : itemTitle,
                audioURL: itemAudio,
                description: desc,
                pubDate: Self.parseDate(itemPubDate),
                durationSeconds: Self.parseDuration(itemDuration),
                artworkURL: itemImage,
                episodeNumber: Int(itemEpisode),
                seasonNumber: Int(itemSeason),
                chapterURL: itemChapterURL,
                transcriptURL: itemTranscriptURL,
                enclosureByteLength: itemEnclosureByteLength,
                episodeType: validEpisodeType
            )
        )
    }

    /// RSS says enclosure length is a byte count. Treat missing, malformed,
    /// zero, negative, and overflowing values as unknown rather than allowing a
    /// hostile or broken feed to invalidate a good local download.
    static func parseEnclosureByteLength(_ raw: String?) -> Int64? {
        guard let raw,
              let value = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else { return nil }
        return value
    }

    /// Prefers Podcasting 2.0 JSON, then WebVTT/SRT, over HTML or plain text.
    /// Structured containers keep cue times separate, allowing the user's
    /// transcript metadata choice to omit timestamps reliably (#900). Equal
    /// ranks preserve feed order so two equivalent resources remain stable.
    private static func transcriptPreference(urlString: String, mimeType: String?) -> Int {
        guard let url = URL(string: urlString) else { return 0 }
        switch TranscriptFormat.detect(url: url, contentType: mimeType) {
        case .json: return 5
        case .webVTT: return 4
        case .srt: return 3
        case .html: return 2
        case .plainText: return 1
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
