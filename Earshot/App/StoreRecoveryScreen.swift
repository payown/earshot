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
///     the public migration floor. Offers restore and erasure only while a
///     verified safety snapshot is available.
///   - ``StoreRecoveryState/corruptStore`` — the store is unreadable. Erasure is
///     likewise unavailable without a verified, restorable snapshot.
struct StoreRecoveryScreen: View {
    let state: StoreRecoveryState
    let backup: MigrationBackupDescriptor?

    init(state: StoreRecoveryState, backup: MigrationBackupDescriptor? = nil) {
        self.state = state
        self.backup = backup
    }

    static let retryLabel = "Try preparing again"
    static let retryHint = "Checks your library again without closing Earshot."
    static let downloadConfirmationMessage =
        "This deletes all downloaded episode audio from this device. Most can be downloaded again, though some podcasts remove older episodes from their feed. Your library, subscriptions, and listening history will not be affected."

    @Environment(AppRuntime.self) private var runtime
    @State private var confirmingReset = false
    @State private var confirmingRestore = false
    @State private var confirmingDownloadRemoval = false
    @State private var didReset = false
    /// Lands VoiceOver on the heading at launch. This screen replaces the main UI
    /// as the WindowGroup root, where auto-focus is unreliable, so focus is
    /// requested explicitly (matches the InboxScreen empty-state pattern).
    @AccessibilityFocusState private var focusedHeader: Bool
    @AccessibilityFocusState private var focusedBackupMessage: Bool
    @AccessibilityFocusState private var focusedRestoreStatus: Bool
    /// Moves VoiceOver to the result text after a reset, so focus isn't orphaned
    /// on the Reset button that was just removed from the tree.
    @AccessibilityFocusState private var focusedDone: Bool
    @AccessibilityFocusState private var focusedStorageResult: Bool
    /// Decorative glyph size, scaled with Dynamic Type so it grows for low-vision
    /// users alongside the text (the glyph itself is hidden from VoiceOver).
    @ScaledMetric private var iconSize: CGFloat = 52

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                Image(systemName: iconName)
                    .font(.system(size: iconSize))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                status

                storageSection

                actions
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity)
        }
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
        .task {
            await runtime.discoverRecoveryBackupIfNeeded()
            await runtime.loadRecoveryDownloadUsageIfNeeded()
        }
        .onChange(of: runtime.recoveryStorageFocusRevision) { _, _ in
            focusedHeader = false
            focusedStorageResult = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                focusedStorageResult = true
            }
        }
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
        if isRestoreResult || storageResultReceivesFocus {
            VStack(spacing: Spacing.md) {
                statusTitle
                statusMessage
            }
            .accessibilityElement(children: .combine)
            .accessibilityFocused(
                isRestoreResult ? $focusedRestoreStatus : $focusedStorageResult
            )
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
    private var storageSection: some View {
        if let storage = runtime.recoveryStorageState,
           storage.freedBytes == nil,
           let downloadBytes = storage.downloadBytes,
           downloadBytes > 0 {
            VStack(spacing: Spacing.sm) {
                Text("Downloaded audio")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.downloadSectionMessage(bytes: downloadBytes))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if state.isBackupUnavailable, runtime.recoveryStorageState != nil {
            storageActions
        } else {
            recoveryActions
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        switch runtime.backupRestorePhase {
        case .restoring:
            ProgressView()
                .accessibilityHidden(true)
        case .restored:
            if state.isUnsupportedSchema {
                resetAction
            } else {
                Button(Self.retryLabel) {
                    runtime.retryLaunch()
                }
                .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
                .buttonStyle(.borderedProminent)
                .accessibilityHint(Self.retryHint)
            }
        case .failed:
            restoreButton(label: "Try restoring again")
            if offersRetry {
                retryButton
            }
            if offersReset {
                resetAction
            }
        case .idle:
            if offersRetry {
                retryButton
            }
            if backup != nil {
                restoreButton(label: "Restore library backup")
            }
            if offersReset {
                resetAction
            }
        }
    }

    @ViewBuilder
    private var storageActions: some View {
        if runtime.isRemovingRecoveryDownloads {
            ProgressView()
                .accessibilityHidden(true)
        } else if let storage = runtime.recoveryStorageState {
            if storage.hasEnoughSpace {
                Button("Prepare library") { runtime.retryLaunch() }
                    .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
                    .buttonStyle(.borderedProminent)
            } else {
                switch storage.deletionOutcome {
                case .some(.partial):
                    deleteDownloadedAudioButton(label: "Try deleting remaining audio")
                    checkAvailableSpaceButton
                case .some(.none):
                    deleteDownloadedAudioButton(label: "Try deleting again")
                    checkAvailableSpaceButton
                case .some(.complete):
                    checkAvailableSpaceButton
                case nil:
                    if let bytes = storage.downloadBytes {
                        if bytes > 0 {
                            deleteDownloadedAudioButton(label: "Delete downloaded audio")
                        } else {
                            checkAvailableSpaceButton
                        }
                    } else {
                        ProgressView()
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func deleteDownloadedAudioButton(label: String) -> some View {
        Button(role: .destructive) { confirmingDownloadRemoval = true } label: {
            Text(label)
                .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
        }
        .buttonStyle(.borderedProminent)
        .confirmationDialog(
            Self.downloadConfirmationTitle(
                bytes: runtime.recoveryStorageState?.downloadBytes ?? 0
            ),
            isPresented: $confirmingDownloadRemoval,
            titleVisibility: .visible
        ) {
            Button("Delete downloaded audio", role: .destructive) {
                Task { await runtime.removeRecoveryDownloads() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.downloadConfirmationMessage)
        }
    }

    private var checkAvailableSpaceButton: some View {
        Button("Check available space") {
            Task { await runtime.checkRecoveryStorage(manual: true) }
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
        .buttonStyle(.bordered)
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
                    Text("Erase entire library and start over")
                        .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .confirmationDialog(
                    resetConfirmationTitle,
                    isPresented: $confirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Erase entire library", role: .destructive) { reset() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(resetConfirmationMessage)
                }
            }
        }
    }

    /// The exact gate used by ``actions``. No recovery condition exposes
    /// destructive recovery unless a validated backup was supplied with the
    /// screen; the action revalidates that backup again before deleting files.
    var offersReset: Bool {
        switch state {
        case .migrationFailed, .backupUnavailable, .storeNewerThanApp:
            return false
        case .storePredatesSupportedSchema, .corruptStore:
            return backup != nil
        }
    }

    var offersRetry: Bool {
        state == .migrationFailed || state.isBackupUnavailable
    }

    private func reset() {
        guard let backup else { return }
        do {
            _ = try ModelContainerFactory.eraseLibrary(
                at: ModelContainerFactory.storeURL,
                preserving: backup
            )
            didReset = true
        } catch {
            AppLog.data.error(
                "Library erasure was blocked because its safety backup could not be revalidated or store files could not be removed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
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
        case .backupUnavailable(
            let requiredFreeSpaceBytes, let availableFreeSpaceBytes
        ):
            if let requiredFreeSpaceBytes, let availableFreeSpaceBytes {
                let amount = Self.formattedStorageRequirement(bytes: max(
                    0, requiredFreeSpaceBytes - availableFreeSpaceBytes
                ))
                return "Earshot couldn't create a safety backup, so preparation did not start. Your library files were not changed. Earshot needs about \(amount) more free space to prepare your library safely. Free up space, then try again."
            }
            return "Earshot couldn't create a safety backup, so preparation did not start. Your library files were not changed. Free up space, then try again."
        case .storeNewerThanApp:
            return "This version of Earshot is older than the data saved on your device. Update to the latest build to open your library. Your podcasts and history are safe and untouched."
        case .storePredatesSupportedSchema:
            if backup != nil {
                return "This version of your library cannot be opened by Earshot, and no compatible upgrade is currently planned. Your library is unchanged and a verified safety backup is available."
            }
            return "Earshot cannot open this older version of your library and could not verify a safety backup. Your library has not been changed. Close Earshot to preserve the files."
        case .corruptStore:
            if backup != nil {
                return "Earshot couldn't read the current library files. A backup from just before preparation is available."
            }
            return "Earshot couldn't read the data saved on this device, and a safety backup could not be verified. Your library has not been changed. Close Earshot to preserve the files."
        }
    }

    /// Uses decimal units to match iOS storage reporting and always rounds up.
    static func formattedStorageRequirement(
        bytes: Int64,
        locale: Locale = .current
    ) -> String {
        let clampedBytes = max(bytes, 0)
        if clampedBytes < 1_000_000_000 {
            return "\(max(1, (clampedBytes + 999_999) / 1_000_000)) MB"
        }
        let tenths = (clampedBytes + 99_999_999) / 100_000_000
        guard !tenths.isMultiple(of: 10) else { return "\(tenths / 10) GB" }
        return "\(tenths / 10)\(locale.decimalSeparator ?? ".")\(tenths % 10) GB"
    }

    /// Approximate allocated sizes round down so deletion results never claim
    /// more space than the filesystem actually released.
    static func formattedApproximateBytes(
        _ bytes: Int64,
        locale: Locale = .current
    ) -> String {
        let clampedBytes = max(bytes, 0)
        if clampedBytes < 1_000_000_000 {
            return "\(clampedBytes / 1_000_000) MB"
        }
        let tenths = clampedBytes / 100_000_000
        guard !tenths.isMultiple(of: 10) else { return "\(tenths / 10) GB" }
        return "\(tenths / 10)\(locale.decimalSeparator ?? ".")\(tenths % 10) GB"
    }

    static func downloadSectionMessage(bytes: Int64) -> String {
        "Downloaded episodes are using about \(formattedApproximateBytes(bytes)) on this device. Most can be downloaded again, though some podcasts remove older episodes from their feed. Your library, subscriptions, and listening history will not be affected."
    }

    static func downloadConfirmationTitle(bytes: Int64) -> String {
        "Delete about \(formattedApproximateBytes(bytes)) of downloaded audio?"
    }

    static func storageTitle(for storage: RecoveryStorageState) -> String {
        if storage.hasEnoughSpace { return "Enough space is available" }
        switch storage.deletionOutcome {
        case .some(.partial): return "Some downloaded audio couldn't be deleted"
        case .some(.none): return "Downloaded audio couldn't be deleted"
        case .some(.complete): return "Earshot still needs more storage"
        case nil: return "Earshot needs more storage"
        }
    }

    static func storageMessage(for storage: RecoveryStorageState) -> String {
        let remaining = formattedStorageRequirement(bytes: storage.remainingBytes)
        guard let freedBytes = storage.freedBytes,
              let outcome = storage.deletionOutcome else {
            if storage.hasEnoughSpace {
                return "You now have enough space to prepare your library."
            }
            return "Earshot couldn't create a safety backup, so preparation did not start. Your library files were not changed. Earshot needs about \(remaining) more free space to prepare your library safely. Free up space, then try again."
        }
        let freed = formattedApproximateBytes(freedBytes)
        switch (outcome, storage.hasEnoughSpace) {
        case (.complete, true):
            return "Earshot freed about \(freed). You now have enough space to prepare your library. Your library, subscriptions, and listening history were not affected."
        case (.complete, false):
            return "Earshot freed about \(freed), but Earshot still needs about \(remaining) more. Your library, subscriptions, and listening history were not affected. Free more space, then return to Earshot."
        case (.partial, true):
            return "Earshot freed about \(freed). Some downloaded audio could not be deleted, but you now have enough space to prepare your library. Your library, subscriptions, and listening history were not affected."
        case (.partial, false):
            return "Earshot freed about \(freed), but Earshot still needs about \(remaining) more. Some downloaded audio could not be deleted. Your library, subscriptions, and listening history were not affected."
        case (.none, _):
            return "Earshot couldn't free space from downloaded audio. Earshot still needs about \(remaining) more. Your library, subscriptions, and listening history were not affected."
        }
    }

    var resetConfirmationTitle: String {
        "Erase your entire library?"
    }

    var resetConfirmationMessage: String {
        "This permanently removes your subscriptions, episodes, folders, Queue, listening history, playback positions, bookmarks, and download records from Earshot. Your verified safety backup will remain on this device for possible support-assisted recovery.\n\nYou can re-import subscriptions from an OPML file, but the other data will not return."
    }

    private var resetDoneMessage: String {
        "The library was erased. A verified safety backup remains on this device for possible support-assisted recovery. Force-quit and reopen Earshot, then import your OPML file."
    }

    private var isRestoreResult: Bool {
        runtime.backupRestorePhase != .idle
    }

    private var displayTitle: String {
        switch runtime.backupRestorePhase {
        case .idle:
            return runtime.recoveryStorageState.map(Self.storageTitle(for:)) ?? title
        case .restoring: return "Restoring library"
        case .restored: return "Library backup restored"
        case .failed: return "Backup couldn't be restored"
        }
    }

    private var displayMessage: String {
        switch runtime.backupRestorePhase {
        case .idle:
            return runtime.recoveryStorageState.map(Self.storageMessage(for:)) ?? message
        case .restoring:
            return "Checking and restoring your backup. Keep Earshot open."
        case .restored:
            if state.isUnsupportedSchema {
                return "Your verified backup was restored. Earshot still cannot open this older library, and no compatible upgrade is currently planned. Close Earshot to preserve the library for possible support-assisted recovery. To use Earshot now, erase the entire library and re-import your subscriptions from an OPML file."
            }
            return "Your library is back to the state saved before preparation. Free up storage before trying preparation again."
        case .failed:
            return "Your current library files were not changed, and the backup is still available. Free up storage and try restoring again."
        }
    }

    private var storageResultReceivesFocus: Bool {
        guard let storage = runtime.recoveryStorageState else { return false }
        return storage.freedBytes != nil || storage.hasEnoughSpace
    }

    var restoreConfirmationMessage: String {
        guard let backup else { return "" }
        let date = backup.createdAt.formatted(date: .long, time: .shortened)
        if state.isUnsupportedSchema {
            return "This replaces the current library files with the verified backup saved on \(date). The restored library still cannot be opened by Earshot."
        }
        return "This replaces your library with the backup saved on \(date), just before preparation started. Earshot will keep the current files until the backup is verified."
    }
}
