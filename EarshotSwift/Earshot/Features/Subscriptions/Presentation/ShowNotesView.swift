import SwiftUI

struct ShowNotesView: View {
    let episode: Episode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(plainNotes)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
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

    /// Readable show notes via the shared HTML strip (#495), with a friendly
    /// placeholder when the episode has no description.
    private var plainNotes: String {
        let text = EpisodeSummary.plainText(episode.episodeDescription)
        return text.isEmpty ? "No show notes for this episode." : text
    }
}
