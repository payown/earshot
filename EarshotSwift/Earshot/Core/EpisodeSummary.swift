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
        var decoded = stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // Decode the general numeric character references feeds use for curly
        // quotes, apostrophes, em dashes, etc. — decimal (&#8217;) and hex
        // (&#x2019; / &#X2019;). Named entities are handled above; this catches
        // everything the common named set misses.
        decoded = Self.decodingNumericEntities(in: decoded)
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
        guard let html, !html.isEmpty else { return [] }
        // Turn block-level closers/breaks into newlines so paragraph structure
        // survives the tag strip. Case-insensitive; tolerates `<br>`, `<br/>`,
        // `<br />`. Inline tags (e.g. <a>, <strong>) are left for plainText to strip.
        let withBreaks = html.replacingOccurrences(
            of: "(?i)</p>|<br\\s*/?>|</div>|</li>|</h[1-6]>|</tr>",
            with: "\n",
            options: .regularExpression
        )
        // Split on the inserted (and any original) newlines, run each chunk through
        // the shared strip (tags + entities + intra-line whitespace collapse), and
        // drop anything that reduces to empty.
        return withBreaks
            .components(separatedBy: "\n")
            .map { plainText($0) }
            .filter { !$0.isEmpty }
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
    /// (#495). Prefers ending at the first sentence boundary within `maxLength`;
    /// otherwise truncates on a word boundary and appends an ellipsis. Returns
    /// `nil` when there is no description, so a row with no notes announces
    /// nothing extra.
    static func shortSummary(_ html: String?, maxLength: Int = 140) -> String? {
        let text = plainText(html)
        guard !text.isEmpty else { return nil }
        guard text.count > maxLength else { return text }

        let chars = Array(text)

        // Prefer ending at the first *substantial* sentence boundary within the
        // cap. The minimum length skips stray early periods (e.g. "Dr." or "1.")
        // so the summary isn't cut to an abbreviation.
        let minSentenceLength = 20
        var index = 0
        while index < chars.count && index < maxLength {
            let c = chars[index]
            if c == "." || c == "!" || c == "?" {
                let endsHere = index + 1 >= chars.count || chars[index + 1] == " "
                if endsHere && (index + 1) >= minSentenceLength {
                    return String(chars[0...index]).trimmingCharacters(in: .whitespaces)
                }
            }
            index += 1
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
