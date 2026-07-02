import SwiftUI

/// Shown at launch when the on-disk store could not be opened safely, in place
/// of the main UI. Replaces the old silent reset-on-failure with an explicit,
/// accessible recovery flow so data is never destroyed without consent (#529).
///
/// Two cases:
///   - ``StoreRecoveryState/storeNewerThanApp`` — the store belongs to a newer
///     build. Purely informational; the store is left intact and the only path
///     forward is updating the app. No destructive action is offered.
///   - ``StoreRecoveryState/corruptStore`` — the store is unreadable. Offers an
///     explicit "Reset local data" action that backs the files up first, then
///     asks the user to relaunch.
struct StoreRecoveryScreen: View {
    let state: StoreRecoveryState

    @State private var confirmingReset = false
    @State private var didReset = false
    @State private var backupName: String?
    /// Lands VoiceOver on the heading at launch. This screen replaces the main UI
    /// as the WindowGroup root, where auto-focus is unreliable, so focus is
    /// requested explicitly (matches the InboxScreen empty-state pattern).
    @AccessibilityFocusState private var focusedHeader: Bool
    /// Moves VoiceOver to the result text after a reset, so focus isn't orphaned
    /// on the Reset button that was just removed from the tree.
    @AccessibilityFocusState private var focusedDone: Bool
    /// Decorative glyph size, scaled with Dynamic Type so it grows for low-vision
    /// users alongside the text (the glyph itself is hidden from VoiceOver).
    @ScaledMetric private var iconSize: CGFloat = 52

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Image(systemName: iconName)
                .font(.system(size: iconSize))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.md) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focusedHeader)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Cold-launch screen replace: VoiceOver's auto-focus is unreliable
            // here, so land focus on the heading explicitly rather than announcing
            // the title — an announce would double-read the header once focus
            // arrives. Delay mirrors InboxScreen's focus-request timing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focusedHeader = true }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .storeNewerThanApp:
            // Informational only — nothing safe to do in-app but update.
            EmptyView()

        case .corruptStore:
            if didReset {
                Text(resetDoneMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($focusedDone)
            } else {
                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Text("Reset local data")
                        .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Backs up the unreadable data, then clears it so Earshot can start fresh")
                .confirmationDialog(
                    "Reset local data?",
                    isPresented: $confirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Reset local data", role: .destructive) { reset() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("A backup copy is saved to this device first. You'll then reopen Earshot to start fresh.")
                }
            }
        }
    }

    private func reset() {
        let backup = ModelContainerFactory.resetCorruptStore(at: ModelContainerFactory.storeURL)
        backupName = backup?.lastPathComponent
        didReset = true
        // The Reset button just left the tree, so VoiceOver focus would be
        // orphaned at the top of the screen. Move it to the result text — which
        // carries the "force-quit and reopen" instruction the user must act on —
        // once the confirmation dialog has finished dismissing. Focus landing
        // reads the message once, so no separate announce is needed (that would
        // double-read it). Delay matches InboxScreen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            focusedDone = true
        }
    }

    // MARK: Copy

    private var iconName: String {
        switch state {
        case .storeNewerThanApp: return "arrow.down.circle"
        case .corruptStore: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch state {
        case .storeNewerThanApp: return "Update Earshot"
        case .corruptStore: return "Couldn't open your data"
        }
    }

    private var message: String {
        switch state {
        case .storeNewerThanApp:
            return "This version of Earshot is older than the data saved on your device. Update to the latest build to open your library. Your podcasts and history are safe and untouched."
        case .corruptStore:
            return "Earshot couldn't read the data saved on this device. You can reset it to start fresh. A backup copy is saved first, so nothing is lost permanently."
        }
    }

    private var resetDoneMessage: String {
        if let backupName {
            return "Local data was reset. A backup was saved as \(backupName). Force-quit Earshot and reopen it to start fresh."
        }
        return "Local data was reset. Force-quit Earshot and reopen it to start fresh."
    }
}
