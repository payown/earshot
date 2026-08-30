import Foundation

/// Shared, pure HTML-to-plain-text helpers for episode descriptions (#495).
/// Previously this strip logic lived privately inside `ShowNotesView`; it now
/// has one tested home so both the full notes view and the brief VoiceOver row
/// summary use the same implementation. SwiftData-free and side-effect-free.
enum EpisodeSummary {

    /// Strips HTML tags and decodes the handful of entities feeds commonly emit,
    /// collapsing the result to clean, trimmed plain text. Returns an empty
    /// string for nil/empty input (callers supply their own placeholder copy).
    static func plainText(_ html: String?) -> String {
        guard let html, !html.isEmpty else { return "" }
        let stripped = html.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        // Decode the named entities feeds commonly emit plus the general numeric
        // character references (curly quotes, em dashes, etc.). Shared with the
        // inline attributed builder so both paths decode identically.
        let decoded = Self.decodingEntities(in: stripped)
        // Collapse the whitespace runs that tag removal leaves behind so the
        // spoken summary doesn't carry awkward gaps.
        let collapsed = decoded.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits an episode description into plain-text paragraphs, preserving the
    /// block structure that ``plainText(_:)`` deliberately flattens (#547).
    ///
    /// ``plainText(_:)`` collapses *all* whitespace — including newlines — into
    /// single spaces, which is right for a one-line row summary but is exactly why
    /// the full Show Notes screen read as a single VoiceOver block. This splits on
    /// block-level HTML boundaries (`</p>`, `<br>`, `</div>`, `</li>`, `</h1-6>`,
    /// `</tr>`) and any literal newlines *before* that collapse, then runs each
    /// chunk through the shared strip so every returned paragraph is its own clean,
    /// entity-decoded plain-text string. Empty chunks are dropped. Returns an empty
    /// array for nil/empty input (callers supply their own placeholder copy).
    ///
    /// Rendering one `Text` per element gives each paragraph its own accessibility
    /// element, so VoiceOver navigates the notes paragraph by paragraph instead of
    /// speaking the whole description at once.
    static func paragraphs(_ html: String?) -> [String] {
        guard let chunks = blockChunks(html) else { return [] }
        // Run each chunk through the shared strip (tags + entities + intra-line
        // whitespace collapse) and drop anything that reduces to empty.
        return chunks
            .map { plainText($0) }
            .filter { !$0.isEmpty }
    }

    /// The attributed sibling of ``paragraphs(_:)`` (#565). Splits the description
    /// on the *exact same* block boundaries as ``paragraphs(_:)`` — via the shared
    /// ``blockChunks(_:)`` — and drops chunks by the *exact same* rule
    /// (``plainText(_:)`` reduces to empty), so the returned array has an identical
    /// count and ordering to `paragraphs(_:)`. This is what preserves the #547
    /// per-paragraph VoiceOver navigation: one element in, one `Text` out.
    ///
    /// Each surviving chunk is parsed for the inline HTML subset feeds actually
    /// use — `<a href>` (as a tappable `.link`), `<strong>`/`<b>` (bold) and
    /// `<em>`/`<i>` (italic) — with named and numeric entities decoded the same
    /// way ``plainText(_:)`` decodes them. Any other inline tag is stripped while
    /// its text is kept, matching `plainText`'s resilience. Only `http`, `https`,
    /// and `mailto` links are kept tappable; `javascript:`, unknown schemes, and
    /// relative URLs (which we have no reliable base to resolve) render as plain
    /// text with no target. If a chunk fails to parse or yields no visible text,
    /// it falls back to `AttributedString(plainText(chunk))` so text is never lost.
    ///
    /// Pure, SwiftData-free, side-effect-free, synchronous. Returns an empty array
    /// for nil/empty input (callers supply their own placeholder copy).
    static func attributedParagraphs(_ html: String?) -> [AttributedString] {
        guard let chunks = blockChunks(html) else { return [] }
        var result: [AttributedString] = []
        for chunk in chunks {
            // Identical drop rule to paragraphs(_:) keeps boundaries in lockstep.
            let plain = plainText(chunk)
            guard !plain.isEmpty else { continue }

            let attributed = attributedInline(from: chunk) ?? AttributedString(plain)
            // Defense in depth: if the inline parse produced no visible text but
            // the plain strip did, prefer the plain text so nothing is dropped.
            if attributed.characters.isEmpty {
                result.append(AttributedString(plain))
            } else {
                result.append(attributed)
            }
        }
        return result
    }

    /// Turns block-level closers/breaks into newlines and splits on them so
    /// paragraph structure survives the tag strip, returning the raw (still
    /// HTML-bearing) chunks. Case-insensitive; tolerates `<br>`, `<br/>`,
    /// `<br />`. Inline tags (e.g. `<a>`, `<strong>`) are left in each chunk for
    /// the caller to strip or parse. Returns `nil` for nil/empty input so callers
    /// can short-circuit to their empty result. Shared by ``paragraphs(_:)`` and
    /// ``attributedParagraphs(_:)`` so both split on exactly the same boundaries.
    private static func blockChunks(_ html: String?) -> [String]? {
        guard let html, !html.isEmpty else { return nil }
        let withBreaks = html.replacingOccurrences(
            of: "(?i)</p>|<br\\s*/?>|</div>|</li>|</h[1-6]>|</tr>",
            with: "\n",
            options: .regularExpression
        )
        return withBreaks.components(separatedBy: "\n")
    }

    /// Named + numeric HTML entity decoding, factored out of ``plainText(_:)`` so
    /// the inline attributed builder decodes byte-for-byte identically (the named
    /// pass runs first, then the numeric pass — order matters for inputs like
    /// `&amp;lt;`). Decimal (`&#8217;`) and hex (`&#x2019;`) references are handled
    /// by ``decodingNumericEntities(in:)``.
    private static func decodingEntities(in text: String) -> String {
        let named = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return decodingNumericEntities(in: named)
    }

    /// The schemes we keep tappable. Anything else (including `javascript:` and
    /// scheme-less relative URLs) is rendered as plain, non-tappable text.
    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// Parses the inline HTML subset of a single paragraph chunk into an
    /// `AttributedString`, applying bold/italic presentation intent and `.link`
    /// runs. Returns `nil` on a parser setup failure so the caller can fall back
    /// to plain text. Kept synchronous and pure — notes are small.
    private static func attributedInline(from chunk: String) -> AttributedString? {
        guard let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>") else { return nil }

        var result = AttributedString()
        // Start `true` so any leading whitespace is trimmed, matching plainText's
        // trim + `\s+`→" " collapse without a second pass over attributed runs.
        var lastWasSpace = true
        var boldDepth = 0
        var italicDepth = 0
        var linkURL: URL?

        func currentAttributes() -> AttributeContainer {
            var container = AttributeContainer()
            var intent: InlinePresentationIntent = []
            if boldDepth > 0 { intent.insert(.stronglyEmphasized) }
            if italicDepth > 0 { intent.insert(.emphasized) }
            if !intent.isEmpty { container.inlinePresentationIntent = intent }
            if let linkURL { container.link = linkURL }
            return container
        }

        func appendText(_ raw: String) {
            let decoded = decodingEntities(in: raw)
            var out = ""
            for character in decoded {
                if character.isWhitespace {
                    if lastWasSpace { continue }
                    out.append(" ")
                    lastWasSpace = true
                } else {
                    out.append(character)
                    lastWasSpace = false
                }
            }
            guard !out.isEmpty else { return }
            var piece = AttributedString(out)
            piece.mergeAttributes(currentAttributes())
            result.append(piece)
        }

        func applyTag(_ tag: String) {
            var body = tag
            body.removeFirst()                               // drop leading '<'
            if body.hasSuffix(">") { body.removeLast() }     // drop trailing '>'
            body = body.trimmingCharacters(in: .whitespaces)
            let isClosing = body.hasPrefix("/")
            if isClosing { body.removeFirst() }
            let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
            switch name {
            case "strong", "b":
                boldDepth = max(0, boldDepth + (isClosing ? -1 : 1))
            case "em", "i":
                italicDepth = max(0, italicDepth + (isClosing ? -1 : 1))
            case "a":
                linkURL = isClosing ? nil : safeHref(in: tag)
            default:
                break                                        // strip, keep text
            }
        }

        let ns = chunk as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var cursor = 0
        for match in tagRegex.matches(in: chunk, range: fullRange) {
            let range = match.range
            if range.location > cursor {
                appendText(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            applyTag(ns.substring(with: range))
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            appendText(ns.substring(from: cursor))
        }

        // Trim the single trailing space the collapse may have left.
        while let last = result.characters.last, last.isWhitespace {
            let end = result.endIndex
            result.removeSubrange(result.index(beforeCharacter: end)..<end)
        }
        return result
    }

    /// Extracts and validates the `href` of an `<a>` tag. Returns a `URL` only for
    /// the allowed schemes (`http`/`https`/`mailto`); returns `nil` for
    /// `javascript:`, unknown schemes, and scheme-less relative URLs (we have no
    /// reliable base to resolve those against), so the anchor text renders plain.
    private static func safeHref(in tag: String) -> URL? {
        let pattern = "(?i)href\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        // Groups 2/3/4 are the double-quoted, single-quoted, and unquoted values.
        var value = ""
        for group in [2, 3, 4] {
            let groupRange = match.range(at: group)
            if groupRange.location != NSNotFound {
                value = ns.substring(with: groupRange)
                break
            }
        }
        // hrefs entity-encode query separators (e.g. `&amp;`), so decode first.
        let raw = decodingEntities(in: value).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              allowedLinkSchemes.contains(scheme) else {
            return nil
        }
        return url
    }

    /// Replaces decimal (`&#NNN;`) and hexadecimal (`&#xHHH;` / `&#XHHH;`)
    /// numeric HTML character references with their Unicode scalars. Leaves any
    /// reference that doesn't resolve to a valid scalar untouched so malformed
    /// input degrades gracefully rather than vanishing.
    private static func decodingNumericEntities(in text: String) -> String {
        guard text.contains("&#") else { return text }
        // &#  optional x/X  digits  ;
        let pattern = "&#[xX]?[0-9A-Fa-f]+;"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        let nsText = text as NSString
        var result = ""
        var lastEnd = 0
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            let range = match.range
            // Append the untouched run before this match.
            result += nsText.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))

            let token = nsText.substring(with: range)
            // Strip leading "&#" and trailing ";".
            var body = String(token.dropFirst(2).dropLast())
            let isHex = body.first == "x" || body.first == "X"
            if isHex { body.removeFirst() }

            if let code = UInt32(body, radix: isHex ? 16 : 10),
               let scalar = Unicode.Scalar(code) {
                result += String(scalar)
            } else {
                // Unresolvable reference: keep the original token verbatim.
                result += token
            }
            lastEnd = range.location + range.length
        }

        // Append the trailing run after the final match.
        result += nsText.substring(from: lastEnd)
        return result
    }

    /// A brief, length-capped plain-text summary for a row's VoiceOver value
    /// (#495). By default it keeps the original single-sentence episode-row
    /// behavior. Callers may request more sentences; podcast rows request two so
    /// a short first line does not consume the whole "Brief" description. It
    /// otherwise ends at a useful sentence boundary or truncates on a word
    /// boundary with an ellipsis. Returns `nil` when there is no description, so
    /// a row with no notes announces nothing extra.
    static func shortSummary(
        _ html: String?,
        maxLength: Int = 140,
        preferredSentenceCount: Int = 1
    ) -> String? {
        let text = plainText(html)
        guard !text.isEmpty else { return nil }
        guard maxLength > 0 else { return nil }
        guard text.count > maxLength else { return text }

        let chars = Array(text)

        // Collect the requested substantial sentence boundaries within the cap. The
        // minimum length skips stray early periods (e.g. "Dr." or "1.") so the
        // summary isn't cut to an abbreviation.
        let minSentenceLength = 20
        var sentenceEnds: [Int] = []
        var index = 0
        while index < chars.count && index < maxLength {
            let c = chars[index]
            if c == "." || c == "!" || c == "?" {
                let endsHere = index + 1 >= chars.count || chars[index + 1] == " "
                if endsHere && (index + 1) >= minSentenceLength {
                    sentenceEnds.append(index)
                    if sentenceEnds.count == max(1, preferredSentenceCount) {
                        return String(chars[0...index]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            index += 1
        }

        // One reasonably full sentence is still a clean stopping point. A short
        // one is not: keep going toward the cap so "Brief" conveys more than a
        // feed's headline-like opening line.
        if preferredSentenceCount > 1,
           let sentenceEnd = sentenceEnds.last,
           sentenceEnd + 1 >= max(40, maxLength / 2) {
            return String(chars[0...sentenceEnd]).trimmingCharacters(in: .whitespaces)
        }

        // No clean sentence break: truncate on the last word boundary and mark
        // it elided.
        let capped = String(chars.prefix(maxLength))
        if let lastSpace = capped.lastIndex(of: " ") {
            let trimmed = String(capped[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed + "…" }
        }
        return capped + "…"
    }
}
