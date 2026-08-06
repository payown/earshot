import SwiftUI

/// Shown at launch when the on-disk store could not be opened safely, in place
/// of the main UI. Replaces the old silent reset-on-failure with an explicit,
/// accessible recovery flow so data is never destroyed without consent (#529).
///
/// Five cases:
///   - ``StoreRecoveryState/migrationFailed`` — migration stopped for an
///     operational reason. Offers an in-process retry against the intact library;
///     no destructive action is offered.
///   - ``StoreRecoveryState/backupUnavailable`` — migration was held behind its
///     safety gate. Offers a retry after the user frees storage.
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
    let backup: MigrationBackupDescriptor?

    init(state: StoreRecoveryState, backup: MigrationBackupDescriptor? = nil) {
        self.state = state
        self.backup = backup
    }

    static let retryLabel = "Try preparing again"
    static let retryHint = "Checks your library again without closing Earshot."

    @Environment(AppRuntime.self) private var runtime
    @State private var confirmingReset = false
    @State private var confirmingRestore = false
    @State private var didReset = false
    @State private var backupName: String?
    /// Lands VoiceOver on the heading at launch. This screen replaces the main UI
    /// as the WindowGroup root, where auto-focus is unreliable, so focus is
    /// requested explicitly (matches the InboxScreen empty-state pattern).
    @AccessibilityFocusState private var focusedHeader: Bool
    @AccessibilityFocusState private var focusedBackupMessage: Bool
    @AccessibilityFocusState private var focusedRestoreStatus: Bool
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

            status

            actions
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Cold-launch screen replace: VoiceOver's auto-focus is unreliable
            // here, so land focus on the heading explicitly rather than announcing
            // the title — an announce would double-read the header once focus
            // arrives. Delay mirrors InboxScreen's focus-request timing.
            _ = runtime.consumeLaunchFocus(.recovery)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                focusedHeader = true
            }
        }
        .task { await runtime.discoverRecoveryBackupIfNeeded() }
        .onChange(of: runtime.backupRestorePhase) { _, phase in
            guard phase != .idle else { return }
            focusedRestoreStatus = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                focusedRestoreStatus = true
            }
        }
        .onChange(of: backup?.directoryURL) { previous, current in
            guard previous == nil, current != nil,
                  runtime.backupRestorePhase == .idle else { return }
            // Existing pre-163 backups need a full integrity check before they
            // can be offered. Move VoiceOver to the approved two-sentence update
            // when that asynchronous check finishes.
            focusedHeader = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                focusedBackupMessage = true
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if isRestoreResult {
            VStack(spacing: Spacing.md) {
                statusTitle
                statusMessage
            }
            .accessibilityElement(children: .combine)
            .accessibilityFocused($focusedRestoreStatus)
        } else {
            VStack(spacing: Spacing.md) {
                statusTitle
                    .accessibilityFocused($focusedHeader)
                statusMessage
                    .accessibilityFocused($focusedBackupMessage)
            }
        }
    }

    private var statusTitle: some View {
        Text(displayTitle)
            .font(.title2.weight(.bold))
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
    }

    private var statusMessage: some View {
        Text(displayMessage)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch runtime.backupRestorePhase {
        case .restoring:
            ProgressView()
                .accessibilityHidden(true)
        case .restored:
            Button(Self.retryLabel) {
                runtime.retryLaunch()
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
            .buttonStyle(.borderedProminent)
            .accessibilityHint(Self.retryHint)
        case .failed:
            restoreButton(label: "Try restoring again")
            if offersRetry {
                retryButton
            }
        case .idle:
            if offersRetry {
                retryButton
            }
            if backup != nil {
                restoreButton(label: "Restore library backup")
            } else if offersReset {
                resetAction
            }
        }
    }

    private var retryButton: some View {
        Button(Self.retryLabel) {
            runtime.retryLaunch()
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
        .buttonStyle(.borderedProminent)
        .accessibilityHint(Self.retryHint)
    }

    private func restoreButton(label: String) -> some View {
        Button(label) {
            confirmingRestore = true
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
        .buttonStyle(.bordered)
        .accessibilityHint(
            "Shows the backup date and what will be replaced before restoring."
        )
        .confirmationDialog(
            "Restore library backup?",
            isPresented: $confirmingRestore,
            titleVisibility: .visible
        ) {
            Button("Restore backup", role: .destructive) {
                runtime.restoreRecoveryBackup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(restoreConfirmationMessage)
        }
    }

    @ViewBuilder
    private var resetAction: some View {
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
        case .migrationFailed, .backupUnavailable, .storeNewerThanApp:
            return false
        case .storePredatesSupportedSchema, .corruptStore:
            return true
        }
    }

    var offersRetry: Bool {
        state == .migrationFailed || state == .backupUnavailable
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
        case .backupUnavailable: return "externaldrive.badge.exclamationmark"
        case .storeNewerThanApp: return "arrow.down.circle"
        case .storePredatesSupportedSchema: return "externaldrive.badge.exclamationmark"
        case .corruptStore: return "exclamationmark.triangle"
        }
    }

    var title: String {
        switch state {
        case .migrationFailed: return "Earshot couldn't finish preparing your library"
        case .backupUnavailable: return "Earshot needs more storage"
        case .storeNewerThanApp: return "Update Earshot"
        case .storePredatesSupportedSchema: return "Older library can't be opened"
        case .corruptStore: return "Couldn't open your data"
        }
    }

    var message: String {
        switch state {
        case .migrationFailed:
            if backup != nil {
                return "Preparation stopped before Earshot could open your library. A backup from just before preparation is available."
            }
            return "Preparation stopped before Earshot could open your library. Your current library files have not been deleted."
        case .backupUnavailable:
            return "Earshot couldn't create a safety backup, so preparation did not start. Your library files were not changed. Free up storage, then try again."
        case .storeNewerThanApp:
            return "This version of Earshot is older than the data saved on your device. Update to the latest build to open your library. Your podcasts and history are safe and untouched."
        case .storePredatesSupportedSchema:
            return "This library was created by a pre-release version of Earshot and is too old to upgrade.\n\nYou can reset it and re-import your subscriptions from an OPML backup. Listening history, queue, and bookmarks can't be restored that way."
        case .corruptStore:
            if backup != nil {
                return "Earshot couldn't read the current library files. A backup from just before preparation is available."
            }
            return "Earshot couldn't read the data saved on this device. You can reset it to start fresh. A copy of the unreadable files is kept for possible support-assisted recovery."
        }
    }

    private var resetHint: String {
        switch state {
        case .storePredatesSupportedSchema:
            return "Backs up the old library, then clears it so you can re-import an OPML file after reopening Earshot"
        case .corruptStore:
            return "Backs up the unreadable data, then clears it so Earshot can start fresh"
        case .migrationFailed, .backupUnavailable, .storeNewerThanApp:
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

    private var isRestoreResult: Bool {
        runtime.backupRestorePhase != .idle
    }

    private var displayTitle: String {
        switch runtime.backupRestorePhase {
        case .idle: return title
        case .restoring: return "Restoring library"
        case .restored: return "Library backup restored"
        case .failed: return "Backup couldn't be restored"
        }
    }

    private var displayMessage: String {
        switch runtime.backupRestorePhase {
        case .idle:
            return message
        case .restoring:
            return "Checking and restoring your backup. Keep Earshot open."
        case .restored:
            return "Your library is back to the state saved before preparation. Free up storage before trying preparation again."
        case .failed:
            return "Your current library files were not changed, and the backup is still available. Free up storage and try restoring again."
        }
    }

    var restoreConfirmationMessage: String {
        guard let backup else { return "" }
        let date = backup.createdAt.formatted(date: .long, time: .shortened)
        return "This replaces your library with the backup saved on \(date), just before preparation started. Earshot will keep the current files until the backup is verified."
    }
}
