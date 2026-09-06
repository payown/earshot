import SwiftUI

/// One versioned document serves both repository readers and offline in-app help.
struct WorkflowGuideSection: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let paragraphs: [String]

    static func parse(_ markdown: String) -> [Self] {
        markdown.components(separatedBy: "\n## ").dropFirst().compactMap { chunk in
            guard let newline = chunk.firstIndex(of: "\n") else { return nil }
            let title = String(chunk[..<newline])
            let paragraphs = chunk[chunk.index(after: newline)...]
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Self(title: title, paragraphs: paragraphs)
        }
    }

    static let bundled: [Self] = {
        guard let url = Bundle.main.url(forResource: "inbox-queue-downloads-guide", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }()
}

struct ListeningWorkflowGuide: View {
    var body: some View {
        List {
            if WorkflowGuideSection.bundled.isEmpty {
                Text("The guide could not be loaded. Please contact us through Send Feedback in Help & About.")
            }
            ForEach(WorkflowGuideSection.bundled) { section in
                Section {
                    ForEach(section.paragraphs, id: \.self) { paragraph in
                        Text(paragraph).textSelection(.enabled)
                    }
                } header: {
                    Text(section.title).accessibilityAddTraits(.isHeader)
                }
            }
        }
        .navigationTitle("Listening workflow guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}
