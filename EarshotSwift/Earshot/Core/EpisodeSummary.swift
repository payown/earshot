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
        let decoded = stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // Collapse the whitespace runs that tag removal leaves behind so the
        // spoken summary doesn't carry awkward gaps.
        let collapsed = decoded.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
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
