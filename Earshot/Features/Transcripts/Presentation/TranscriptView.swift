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

    /// One transcript segment: the selected source metadata (distinct, secondary,
    /// caption-weight) above the spoken text. The segment remains one VoiceOver
    /// element while its label follows the same setting as the visible metadata.
    private func segmentView(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let metadata = TranscriptSegmentPresentation.metadataText(
                for: segment,
                mode: settings.transcriptExportMetadata
            ) {
                Text(metadata)
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
        // One element per segment; author the spoken form so metadata and text
        // are read together rather than becoming separate navigation stops.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TranscriptSegmentPresentation.spokenText(
            for: segment,
            mode: settings.transcriptExportMetadata
        ))
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

/// Pure presentation rules shared by visible transcript metadata and the
/// segment's single VoiceOver label. Keeping this separate makes all three
/// live-view modes testable without changing focus structure.
enum TranscriptSegmentPresentation {
    static func metadataText(
        for segment: TranscriptSegment,
        mode: TranscriptExportMetadata
    ) -> String? {
        let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usefulSpeaker = speaker.flatMap { $0.isEmpty ? nil : $0 }
        let timestamp = segment.startSeconds.map {
            "[\(TranscriptMarkdownExporter.timestamp($0))]"
        }

        return switch mode {
        case .speakersOnly:
            usefulSpeaker
        case .timestampsOnly:
            timestamp
        case .speakersAndTimestamps:
            [timestamp, usefulSpeaker].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }
    }

    static func spokenText(
        for segment: TranscriptSegment,
        mode: TranscriptExportMetadata
    ) -> String {
        let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usefulSpeaker = speaker.flatMap { $0.isEmpty ? nil : $0 }
        let timestamp = segment.startSeconds.map(spokenTimestamp)

        let prefix: String? = switch mode {
        case .speakersOnly:
            usefulSpeaker
        case .timestampsOnly:
            timestamp
        case .speakersAndTimestamps:
            [timestamp, usefulSpeaker].compactMap { $0 }.joined(separator: ", ").nilIfEmpty
        }
        return prefix.map { "\($0): \(segment.text)" } ?? segment.text
    }

    private static func spokenTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remaining = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if remaining > 0 || parts.isEmpty {
            parts.append("\(remaining) \(remaining == 1 ? "second" : "seconds")")
        }
        return parts.joined(separator: ", ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
