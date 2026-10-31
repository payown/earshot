import SwiftUI

struct InterruptedLibraryResetScreen: View {
    let reason: InterruptedLibraryResetReason
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.clockwise")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text(reason.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(reason.message)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
