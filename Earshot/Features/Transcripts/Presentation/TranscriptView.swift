import SwiftUI

/// Reads an episode transcript in a scrollable, VoiceOver-navigable sheet (#451).
/// Presented from the Now Playing screen the same way ``ShowNotesView`` is, and
/// mirrors its per-paragraph model (#547): one `Text` per parsed segment so each is
/// its own VoiceOver element and the transcript can be navigated segment by segment
/// rather than read as one continuous block.
///
/// Purely presentational. The fetch and parse live in ``TranscriptService``; this
/// view only observes ``TranscriptViewModel`` and renders its three states —
/// loading, loaded, and a friendly error with Retry.
struct TranscriptView: View {
    /// The episode supplies the transcript URL plus export heading and filename
    /// metadata. Optional so the view still degrades to its friendly empty state.
    let episode: Episode?

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @State private var model = TranscriptViewModel()
    @State private var exportFile: ExportFile?

    private var transcriptURL: String? { episode?.transcriptURL }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Transcript")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if case .loaded(let segments) = model.state {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                export(segments)
                            } label: {
                                Label("Export transcript", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await model.load(urlString: transcriptURL) }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            loadingView
        case .loaded(let segments):
            transcriptScroll(segments)
        case .failed(let error):
            errorView(error)
        }
    }

    // MARK: Loading

    private var loadingView: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
            Text("Loading transcript…")
                .font(.body)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        // Collapse the spinner + caption into one spoken element so VoiceOver lands
        // on a single "Loading transcript" stop rather than two.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading transcript")
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Loaded

    /// The parsed transcript: one `Text` per segment in a `LazyVStack` so long
    /// transcripts stay light, each segment a single VoiceOver element. `id: \.offset`
    /// is stable for a static, read-only list that never reorders.
    private func transcriptScroll(_ segments: [TranscriptSegment]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One transcript segment: an optional speaker label (distinct, secondary,
    /// caption-weight) above the spoken text. Rendered as a single VoiceOver element
    /// whose spoken label is "Speaker: text" so the reader hears who is speaking
    /// before the line, while the visible text stays selectable.
    private func segmentView(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let speaker = segment.speaker, !speaker.isEmpty {
                Text(speaker)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppColor.secondaryText)
                    .textCase(nil)
            }
            Text(segment.text)
                .font(.body)
                .foregroundStyle(AppColor.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element per segment; author the spoken form so the speaker is named
        // before the line ("Speaker: text") rather than read as two stray stops.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSegment(segment))
    }

    /// The spoken form of a segment: "Speaker: text" when a speaker is credited,
    /// otherwise just the text.
    private func spokenSegment(_ segment: TranscriptSegment) -> String {
        if let speaker = segment.speaker, !speaker.isEmpty {
            return "\(speaker): \(segment.text)"
        }
        return segment.text
    }

    // MARK: Error

    /// A friendly, accessible failure: an icon + headline (error signalled by icon +
    /// text, never colour alone), the specific reason where it adds detail, and a
    /// Retry button that re-runs the load. Empty transcripts get their own gentle
    /// "no transcript" headline rather than a scary error.
    private func errorView(_ error: TranscriptError) -> some View {
        VStack(spacing: Spacing.md) {
            Label {
                Text(headline(for: error))
                    .font(.headline)
                    .multilineTextAlignment(.center)
            } icon: {
                Image(systemName: isEmpty(error) ? "text.bubble" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isEmpty(error) ? AppColor.secondaryText : AppColor.error)
            }

            if let detail = detail(for: error) {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(AppColor.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await model.load(urlString: transcriptURL) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Tries to load the transcript again")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func isEmpty(_ error: TranscriptError) -> Bool {
        error == .empty
    }

    /// The friendly top-line message. Empty gets a gentle "no transcript" line; every
    /// other failure gets a single reassuring headline with the specifics in `detail`.
    private func headline(for error: TranscriptError) -> String {
        isEmpty(error)
            ? "No transcript available for this episode."
            : "This transcript couldn't be loaded."
    }

    /// The specific reason, shown under the headline. Suppressed for `.empty` (the
    /// headline already says it all) so there's no redundant second line.
    private func detail(for error: TranscriptError) -> String? {
        isEmpty(error) ? nil : error.errorDescription
    }

    private func export(_ segments: [TranscriptSegment]) {
        do {
            exportFile = ExportFile(url: try TranscriptViewerExport.write(
                podcastTitle: episode?.podcast?.title,
                episodeTitle: episode?.title ?? "Episode",
                publicationDate: episode?.pubDate,
                segments: segments,
                metadata: settings.transcriptExportMetadata
            ))
        } catch {
            AppLog.data.error(
                "Transcript export failed: \(error.localizedDescription, privacy: .public)"
            )
            Announcer.announce("Could not export transcript")
        }
    }
}
