import SwiftUI

struct InterruptedLibraryResetScreen: View {
    static let headingAccessibilityIdentifier = "interruptedLibraryReset.heading"

    let reason: InterruptedLibraryResetReason
    let retry: () -> Void
    @AccessibilityFocusState private var focusedHeader: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.clockwise")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text(reason.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focusedHeader)
                .accessibilityIdentifier(Self.headingAccessibilityIdentifier)
            Text(reason.message)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            // This screen replaces the app's root at launch; VoiceOver does
            // not reliably auto-focus new root content. Match the established
            // store-recovery heading handoff without a competing announcement.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                focusedHeader = true
            }
        }
    }
}
