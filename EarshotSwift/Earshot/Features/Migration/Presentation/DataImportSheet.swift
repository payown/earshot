import SwiftUI
import SwiftData

/// The Settings → Data "Import older data" sheet (#429). Explains what the import
/// does, runs it on demand with a progress indicator, and shows the result —
/// success or a retryable failure. Separate from onboarding's migration sheet:
/// this one has no "Remind me later", is reachable any time, and is always
/// dismissible via the Done control (no drag-only dismissal).
struct DataImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var viewModel: DataImportViewModel?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import older data")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityLabel("Done")
                            .accessibilityHint("Close and return to Settings")
                    }
                }
        }
        // Dismissable without a drag: the Done button above is the explicit close.
        .accessibilityAction(.escape) { dismiss() }
        .onAppear {
            if viewModel == nil {
                viewModel = DataImportViewModel(context: context)
            } else {
                viewModel?.refresh()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let viewModel {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    explainer
                    actionArea(viewModel)
                    if viewModel.hasResult {
                        resultLine(viewModel)
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Brief frame before the view model is created on appear.
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Import older data")
                .font(.title2)
                .bold()
                .accessibilityAddTraits(.isHeader)

            Text("This brings over your shows, your played and inbox state, and your queue from the previous version of Earshot. It's safe to run more than once — nothing gets duplicated.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func actionArea(_ viewModel: DataImportViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Button {
                Task { await viewModel.runImport() }
            } label: {
                Text(viewModel.isRunning ? "Importing…" : "Import now")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunning)
            .accessibilityHint(viewModel.isRunning
                ? "Import in progress"
                : "Brings your older data into this version")

            if viewModel.isRunning {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                    Text("Importing your older data…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // Treat the spinner + label as one VoiceOver stop.
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Importing your older data")
            }
        }
    }

    private func resultLine(_ viewModel: DataImportViewModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: viewModel.status == .succeeded
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(viewModel.status == .succeeded ? .green : .orange)
                .accessibilityHidden(true)
            Text(viewModel.resultText)
                .font(.callout)
        }
        // Icon + text read as one stop; the icon is decorative (color is not the
        // only signal — the text states the outcome).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.resultText)
    }
}
