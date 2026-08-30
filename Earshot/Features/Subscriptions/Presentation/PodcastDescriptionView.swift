import SwiftUI

/// Value-owned sheet state for opening a podcast's full description from a row
/// action. Keeping only strings avoids retaining a SwiftData model while the
/// sheet is presented and lets subscribed and directory podcasts share the view.
struct PodcastDescriptionPresentation: Identifiable {
    let id = UUID()
    let title: String
    let descriptionHTML: String

    init?(title: String, descriptionHTML: String?) {
        guard let descriptionHTML,
              !descriptionHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.title = title
        self.descriptionHTML = descriptionHTML
    }
}

/// A bounded-description row's "Read full description" destination. Paragraphs
/// remain separate accessibility elements so VoiceOver users can move through a
/// long description without listening to one uninterruptible announcement.
struct PodcastDescriptionView: View {
    let presentation: PodcastDescriptionPresentation

    @Environment(\.dismiss) private var dismiss

    private struct Paragraph: Identifiable {
        let id: String
        let text: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text(presentation.title)
                        .font(.title2)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(paragraphs) { paragraph in
                        Text(paragraph.text)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }
            .navigationTitle("Podcast Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityHint("Closes the podcast description")
                }
            }
        }
    }

    private var paragraphs: [Paragraph] {
        let paragraphs = EpisodeSummary.paragraphs(presentation.descriptionHTML)
        let visible = paragraphs.isEmpty
            ? ["No description is available for this podcast."]
            : paragraphs
        // The presentation is immutable for the sheet's lifetime. Combining the
        // fixed position with text gives duplicate paragraphs distinct, stable
        // identities without relying on ForEach indices or mutable model fields.
        return visible.enumerated().map { index, text in
            Paragraph(id: "\(index):\(text)", text: text)
        }
    }
}
