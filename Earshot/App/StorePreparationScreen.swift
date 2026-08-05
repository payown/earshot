import SwiftUI

/// The accessible first frame for an existing library while the restartable
/// store migration/open runs away from the application launch watchdog (#781).
/// Focus remains on one status element; progress changes are spoken only through
/// ``Announcer`` and never through a competing SwiftUI live region.
struct StorePreparationScreen: View {
    @Environment(AppRuntime.self) private var runtime
    @AccessibilityFocusState private var focusedStatus: Bool
    @ScaledMetric private var iconSize: CGFloat = 52

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.md) {
                Text("Preparing Earshot")
                    .font(.title2.weight(.bold))

                Text(visualStageText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppRuntime.preparationAccessibilityLabel)
            .accessibilityValue(runtime.preparationStatusValue)
            .accessibilityFocused($focusedStatus)

            ProgressView(value: Double(runtime.preparationStep), total: 3)
                .progressViewStyle(.linear)
                // VoiceOver must never announce an inferred percentage. The
                // status element above is the sole accessible progress source.
                .accessibilityHidden(true)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Give SwiftUI one presentation turn, request focus on the initial
            // status, then start the runtime-owned task. The short handoff is not
            // a migration timeout; it ensures the first accessible frame exists
            // before the engine emits its immediate Step 1 update.
            await Task.yield()
            focusedStatus = true
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            runtime.startLaunchIfNeeded()
        }
    }

    private var visualStageText: String {
        switch runtime.launchProgress {
        case .preparingAndValidating:
            return "Step 1 of 3: Preparing your library data"
        case .migratingMirroredStore:
            return "Step 2 of 3: Reorganizing your episodes"
        case .openingAndRepairing:
            return "Step 3 of 3: Finishing preparation"
        case nil:
            return "Checking your library. Keep the app open."
        }
    }
}
