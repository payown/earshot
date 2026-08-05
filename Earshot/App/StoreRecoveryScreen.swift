import SwiftUI

/// Shown at launch when the on-disk store could not be opened safely, in place
/// of the main UI. Replaces the old silent reset-on-failure with an explicit,
/// accessible recovery flow so data is never destroyed without consent (#529).
///
/// Four cases:
///   - ``StoreRecoveryState/migrationFailed`` — migration stopped for an
///     operational reason. Purely informational; reopening retries against the
///     intact library, and no destructive action is offered.
///   - ``StoreRecoveryState/storeNewerThanApp`` — the store belongs to a newer
///     build. Purely informational; the store is left intact and the only path
///     forward is updating the app. No destructive action is offered.
///   - ``StoreRecoveryState/storePredatesSupportedSchema`` — the store predates
///     the first public schema. Offers a backed-up reset and points to OPML
///     re-import as the subscription recovery path.
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
        if offersReset {
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
                .accessibilityHint(resetHint)
                .confirmationDialog(
                    resetConfirmationTitle,
                    isPresented: $confirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Reset local data", role: .destructive) { reset() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(resetConfirmationMessage)
                }
            }
        }
    }

    /// The exact gate used by ``actions``. Operational and downgrade failures
    /// are informational only and must never expose destructive recovery.
    var offersReset: Bool {
        switch state {
        case .migrationFailed, .storeNewerThanApp:
            return false
        case .storePredatesSupportedSchema, .corruptStore:
            return true
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
        case .migrationFailed: return "externaldrive.badge.exclamationmark"
        case .storeNewerThanApp: return "arrow.down.circle"
        case .storePredatesSupportedSchema: return "externaldrive.badge.exclamationmark"
        case .corruptStore: return "exclamationmark.triangle"
        }
    }

    var title: String {
        switch state {
        case .migrationFailed: return "Earshot couldn't finish preparing your library"
        case .storeNewerThanApp: return "Update Earshot"
        case .storePredatesSupportedSchema: return "Older library can't be opened"
        case .corruptStore: return "Couldn't open your data"
        }
    }

    var message: String {
        switch state {
        case .migrationFailed:
            return "Your library is safe and untouched. This usually means your device is low on storage. Free up some space, then quit Earshot from the App Switcher and open it again to try."
        case .storeNewerThanApp:
            return "This version of Earshot is older than the data saved on your device. Update to the latest build to open your library. Your podcasts and history are safe and untouched."
        case .storePredatesSupportedSchema:
            return "This library was created by a pre-release version of Earshot and is too old to upgrade.\n\nYou can reset it and re-import your subscriptions from an OPML backup. Listening history, queue, and bookmarks can't be restored that way."
        case .corruptStore:
            return "Earshot couldn't read the data saved on this device. You can reset it to start fresh. A backup copy is saved first, so nothing is lost permanently."
        }
    }

    private var resetHint: String {
        switch state {
        case .storePredatesSupportedSchema:
            return "Backs up the old library, then clears it so you can re-import an OPML file after reopening Earshot"
        case .corruptStore:
            return "Backs up the unreadable data, then clears it so Earshot can start fresh"
        case .migrationFailed, .storeNewerThanApp:
            return ""
        }
    }

    private var resetConfirmationTitle: String {
        state == .storePredatesSupportedSchema ? "Reset old library?" : "Reset local data?"
    }

    private var resetConfirmationMessage: String {
        if state == .storePredatesSupportedSchema {
            return "A backup copy is saved to this device first. After you reopen Earshot, re-import your subscriptions from an OPML file."
        }
        return "A backup copy is saved to this device first. You'll then reopen Earshot to start fresh."
    }

    private var resetDoneMessage: String {
        if state == .storePredatesSupportedSchema {
            if let backupName {
                return "The old local library was reset. A backup was saved as \(backupName). Force-quit and reopen Earshot, then import your OPML file."
            }
            return "The old local library was reset. Force-quit and reopen Earshot, then import your OPML file."
        }
        if let backupName {
            return "Local data was reset. A backup was saved as \(backupName). Force-quit Earshot and reopen it to start fresh."
        }
        return "Local data was reset. Force-quit Earshot and reopen it to start fresh."
    }
}
