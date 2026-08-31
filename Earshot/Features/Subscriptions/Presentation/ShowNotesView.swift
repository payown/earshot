import SwiftUI

struct ShowNotesView: View {
    let episode: Episode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                // One Text per paragraph so each is its own VoiceOver element and
                // the notes can be navigated paragraph by paragraph instead of read
                // as one continuous block (#547). `id: \.offset` is stable for a
                // static, read-only list that never reorders.
                LazyVStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding()
                // Defense in depth: the builder already drops unsafe schemes, but
                // scope an explicit policy to the notes so only http(s)/mailto ever
                // open and anything else is discarded rather than handed to the OS.
                .environment(\.openURL, OpenURLAction { url in
                    guard let scheme = url.scheme?.lowercased(),
                          Self.openableLinkSchemes.contains(scheme) else {
                        return .discarded
                    }
                    return .systemAction
                })
            }
            .navigationTitle("Show notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Readable show notes split into paragraphs via the shared HTML parser, with
    /// tappable `<a href>` links and inline bold/italic preserved as attributed
    /// runs (#565, building on #547 and #495). Kept as one `AttributedString` per
    /// paragraph so each stays its own VoiceOver element (#547). A friendly
    /// placeholder shows when the episode has no description.
    private var paragraphs: [AttributedString] {
        let interval = PerformanceSignposts.signposter.beginInterval("ShowNotesParse")
        defer { PerformanceSignposts.signposter.endInterval("ShowNotesParse", interval) }
        let paragraphs = EpisodeSummary.attributedParagraphs(episode.episodeDescription)
        return paragraphs.isEmpty
            ? [AttributedString("No show notes for this episode.")]
            : paragraphs.map(Self.underliningLinks)
    }

    /// Underlines every `.link` run so links are distinguished from surrounding
    /// body text by an underline, not tint color alone (WCAG 1.4.1 Use of Color).
    /// This is done here in the SwiftUI layer rather than in the Foundation-only
    /// `EpisodeSummary` builder, which has no access to `Text.LineStyle`. Ranges
    /// are collected first so mutation doesn't invalidate the run iterator; a link
    /// run's character range stays valid when only its attributes change.
    private static func underliningLinks(_ input: AttributedString) -> AttributedString {
        let linkRanges = input.runs.compactMap { $0.link != nil ? $0.range : nil }
        guard !linkRanges.isEmpty else { return input }
        var output = input
        for range in linkRanges {
            output[range].underlineStyle = Text.LineStyle.single
        }
        return output
    }

    /// Schemes the notes will actually open. Mirrors the builder's allow-list.
    private static let openableLinkSchemes: Set<String> = ["http", "https", "mailto"]
}
