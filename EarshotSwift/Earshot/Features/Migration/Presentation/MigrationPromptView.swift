#if IS_BETA_BUILD
import SwiftUI
import SwiftData

/// First-launch prompt (beta builds only) offering to import the tester's
/// subscriptions from the previous Flutter build. A full screen, not a banner —
/// this is a significant moment and the copy is honest about the tradeoffs.
/// Wrapped in `#if IS_BETA_BUILD` so it is absent from the App Store binary.
struct MigrationPromptView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isImporting = false
    @State private var reminderCount = 0
    @State private var showingOPMLInstructions = false
    @AccessibilityFocusState private var titleFocused: Bool

    private var canRemindLater: Bool {
        MigrationGate.canRemindLater(reminderCount: reminderCount)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                whatsHappening
                tradeoffs
                callToAction
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Back up from the previous app", isPresented: $showingOPMLInstructions) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open the previous version of Earshot, go to Settings, then Export subscriptions to save an OPML backup. Come back here when you're done.")
        }
        .onAppear {
            reminderCount = FlutterMigrationService(context: modelContext).reminderCount
            titleFocused = true
        }
    }

    // MARK: Section 1 — what's happening

    private var whatsHappening: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Earshot is moving to a new version")
                .font(.largeTitle).bold()
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)

            Text("You're one of the people who helped shape this app. The version you've been using was built with Flutter. We've rebuilt Earshot from scratch in Swift, the native iOS language, and this is that new version.")

            Text("The new build is faster, more accessible, and will be the version that goes to the App Store. Going forward, all updates will happen here.")
        }
    }

    // MARK: Section 2 — options and honest tradeoffs

    private var tradeoffs: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Before you continue, here's what you should know")
                .font(.title2).bold()
                .accessibilityAddTraits(.isHeader)

            Text("Your current podcasts, playback history, queue, and listening position are stored in the previous version of the app. We can import your subscriptions automatically, but playback position, queue order, and listening history will not carry over in this first release. We're working on it.")

            Text("If you want to keep your data safe before switching:")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Button {
                showingOPMLInstructions = true
            } label: {
                Label("Export my subscriptions as OPML", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Saves your podcast list as a file you can use as a backup")

            Text("If you want to go back to the previous version:")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("The Flutter version of Earshot is still on your phone. You can find it and keep using it. It will continue to work, but it will not receive further updates. When you're ready to switch, this option will still be here.")
        }
    }

    // MARK: Section 3 — call to action

    @ViewBuilder
    private var callToAction: some View {
        if isImporting {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text("Importing your subscriptions…")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.md)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Importing your subscriptions")
            .accessibilityAddTraits(.updatesFrequently)
        } else {
            VStack(spacing: Spacing.md) {
                Button(action: importAndSwitch) {
                    Text("Import my podcasts and switch")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: startFresh) {
                    Text("Start fresh")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if canRemindLater {
                    Button("Remind me later", action: remindLater)
                        .padding(.vertical, Spacing.sm)
                        .padding(.top, Spacing.xs)
                }
            }
            .padding(.top, Spacing.md)
        }
    }

    // MARK: Actions

    private func importAndSwitch() {
        isImporting = true
        // Confirm the action took effect immediately; the completion announcement
        // arrives seconds later, so don't leave the user in silence until then.
        Announcer.announce("Importing your subscriptions")
        Task {
            let service = FlutterMigrationService(context: modelContext)
            let count = await service.importSubscriptions()
            service.markComplete()
            isImporting = false
            let message = "Done. \(count) \(count == 1 ? "podcast" : "podcasts") imported. Your queue and history will need to be rebuilt."
            dismiss()
            announceAfterDismiss(message)
        }
    }

    private func startFresh() {
        FlutterMigrationService(context: modelContext).markComplete()
        dismiss()
        announceAfterDismiss(
            "Starting fresh. You can add podcasts from the Library tab or import an OPML file in Settings."
        )
    }

    private func remindLater() {
        FlutterMigrationService(context: modelContext).recordReminderDismissal()
        dismiss()
    }

    /// Posts a VoiceOver announcement after a short delay so it isn't clobbered by
    /// the sheet-dismissal utterance. Runs in its own task so it survives this
    /// view's teardown after `dismiss()`.
    @MainActor
    private func announceAfterDismiss(_ message: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            Announcer.announce(message)
        }
    }
}
#endif
