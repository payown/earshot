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
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding()
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

    /// Readable show notes split into plain-text paragraphs via the shared HTML
    /// strip (#547, building on #495), with a friendly placeholder when the episode
    /// has no description.
    private var paragraphs: [String] {
        let paragraphs = EpisodeSummary.paragraphs(episode.episodeDescription)
        return paragraphs.isEmpty ? ["No show notes for this episode."] : paragraphs
    }
}
