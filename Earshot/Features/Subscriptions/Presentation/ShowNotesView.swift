import SwiftUI

struct ShowNotesView: View {
    let episode: Episode
    @Environment(\.dismiss) private var dismiss
    @State private var paragraphs: [AttributedString] = []
    @State private var hasPreparedParagraphs = false

    var body: some View {
        NavigationStack {
            ScrollView {
                // One Text per paragraph so each is its own VoiceOver element and
                // the notes can be navigated paragraph by paragraph instead of read
                // as one continuous block (#547). `id: \.offset` is stable for a
                // static, read-only list that never reorders.
                if hasPreparedParagraphs {
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
                } else {
                    ProgressView("Preparing show notes")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            .navigationTitle("Show notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: episode.persistentModelID) {
            let source = episode.episodeDescription
            let prepared = await ShowNotesPreparation.prepare(source)
            guard !Task.isCancelled else { return }
            paragraphs = prepared.map(Self.underliningLinks)
            hasPreparedParagraphs = true
        }
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

/// Parses immutable source text away from the main actor. Only Sendable value
/// types cross back into SwiftUI; SwiftData models never leave their context.
enum ShowNotesPreparation {
    static func prepare(_ source: String?) async -> [AttributedString] {
        await Task.detached(priority: .userInitiated) {
            let interval = PerformanceSignposts.signposter.beginInterval("ShowNotesParse")
            defer { PerformanceSignposts.signposter.endInterval("ShowNotesParse", interval) }
            let parsed = EpisodeSummary.attributedParagraphs(source)
            return parsed.isEmpty
                ? [AttributedString("No show notes for this episode.")]
                : parsed
        }.value
    }
}
