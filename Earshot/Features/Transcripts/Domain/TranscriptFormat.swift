import Foundation

/// The transcript container formats Earshot can parse (#451).
///
/// A Podcasting 2.0 `<podcast:transcript>` tag carries a `url` and a MIME
/// `type`, but the feed parser only stored the URL (RSSParser). So the format
/// is resolved at fetch time from the URL path extension first, then the
/// response `Content-Type` header — see ``detect(url:contentType:)``.
///
/// `String` raw values are stable, lowercase-ish identifiers used only for
/// logging and test assertions; they are not parsed from feeds.
enum TranscriptFormat: String, Equatable, Sendable {
    case webVTT
    case srt
    case json
    case html
    case plainText

    /// Resolves the transcript format for a fetched resource.
    ///
    /// Resolution order (first match wins):
    /// 1. **URL path extension** — the most reliable signal for hand-authored
    ///    transcript files: `vtt`→``webVTT``, `srt`→``srt``, `json`→``json``,
    ///    `html`/`htm`→``html``, `txt`→``plainText``.
    /// 2. **Explicit URL format query** — transcript endpoints sometimes expose
    ///    the selected representation as `format=SubRip` or `format=WebVTT`
    ///    while serving every representation as `text/plain` (notably Omny).
    /// 3. **`Content-Type` MIME** (base type, any `; charset=…` parameter is
    ///    dropped): `text/vtt`→``webVTT``; `application/x-subrip`, `application/srt`,
    ///    `text/srt`→``srt``; `application/json`, `text/json`→``json``;
    ///    `text/html`, `application/xhtml+xml`→``html``; `text/plain``→``plainText``.
    /// 4. Anything unrecognised defaults to ``plainText`` — the most forgiving
    ///    parser, so an unknown body still yields best-effort paragraphs rather
    ///    than nothing.
    ///
    /// Pure and side-effect-free so it is unit-testable without networking.
    static func detect(url: URL, contentType: String?) -> TranscriptFormat {
        switch url.pathExtension.lowercased() {
        case "vtt": return .webVTT
        case "srt": return .srt
        case "json": return .json
        case "html", "htm": return .html
        case "txt": return .plainText
        default: break
        }

        // An explicit representation in the URL is more trustworthy than a
        // generic response MIME. Omny, for example, advertises SRT in RSS and
        // uses `format=SubRip`, but responds with `Content-Type: text/plain`.
        // Without this check cue indices and timing lines become transcript text
        // and can no longer be omitted by the export metadata preference (#900).
        if let queryFormat = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("format") == .orderedSame })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            switch queryFormat {
            case "webvtt", "vtt": return .webVTT
            case "subrip", "srt": return .srt
            case "json": return .json
            case "html": return .html
            case "text", "plain", "plaintext", "textwithtimestamps": return .plainText
            default: break
            }
        }

        if let contentType {
            // Drop any parameter (e.g. "text/vtt; charset=utf-8") and normalise.
            let base = contentType
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces)
                .lowercased() ?? ""
            switch base {
            case "text/vtt":
                return .webVTT
            case "application/x-subrip", "application/srt", "text/srt":
                return .srt
            case "application/json", "text/json":
                return .json
            case "text/html", "application/xhtml+xml":
                return .html
            case "text/plain":
                return .plainText
            default:
                break
            }
        }

        return .plainText
    }
}
