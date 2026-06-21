import SwiftUI

/// A determinate "Loading episodes: N of M" banner shown at the top of the tabs
/// while episodes load in the background after a migration restore. It is a single
/// VoiceOver element whose value carries the live count, so a screen-reader user
/// can swipe to it to re-check progress on demand. It never takes focus and there
/// are no spoken progress updates — background loading must not interrupt the
/// user's navigation; the banner is the on-demand, swipe-to-check status.
struct RestoreBanner: View {
    let completed: Int
    let total: Int

    var body: some View {
        HStack(spacing: Spacing.md) {
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .frame(width: 28)
                .accessibilityHidden(true)
            Text("Loading episodes: \(completed) of \(total)")
                .font(.subheadline)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(.bar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading episodes")
        .accessibilityValue("\(completed) of \(total) shows")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
