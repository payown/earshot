import SwiftUI

/// Full-cover progress shown over the active tab while a bulk OPML import runs.
/// Presented from ``RootView`` as a sheet bound to ``OPMLImportProgress/isImporting``
/// and auto-dismissed when that flips false — there is no manual dismiss or cancel
/// for v1; the import is short and the existing "Imported N podcasts" announcement
/// in ``OPMLFileImporter`` closes the loop on completion.
///
/// VoiceOver behavior (deliberately quiet to avoid chatter):
///  - On appearance, a SINGLE assertive announcement ("Importing N podcasts")
///    tells the user the screen opened and what it's doing. We do NOT announce per
///    feed — ten feeds would be ten interruptions. (`OPMLFileImporter` already
///    makes the final "Imported N podcasts" announcement when the import settles.)
///  - Live progress is EXPOSED, not spoken: the count + current title live in a
///    single accessibility element whose value updates, so a user can swipe to it
///    and re-check "3 of 10" on demand without it being forced into their ear on
///    every tick. `.updatesFrequently` lets VoiceOver re-read on demand.
///  - The heading is a single header element; focus rests on the content, never
///    yanked mid-import (no autofocus on a container).
struct ImportProgressView: View {
    let progress: OPMLImportProgress

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Determinate fraction for the bar; clamps total to ≥1 so an empty/early
    /// import shows an empty bar rather than dividing by zero.
    private var fraction: Double {
        Double(progress.completed) / Double(max(progress.total, 1))
    }

    /// Spoken status that a VoiceOver user hears when they focus the progress
    /// element. Kept short: count first, then the current title when present.
    private var statusValue: String {
        let count = "\(progress.completed) of \(progress.total)"
        if let title = progress.currentTitle, !title.isEmpty {
            return "\(count). \(title)"
        }
        return count
    }

    var body: some View {
        VStack(spacing: Spacing.xl) {
            // Heading: one header element, explicit label so the Text doesn't make a
            // second node (project header-semantics pattern).
            Text("Importing podcasts")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            // The live progress block is one accessibility element: a labeled,
            // determinate bar plus the visible count and current title. Children are
            // ignored so VoiceOver reads the single composed label + value, and the
            // value updates as the import advances.
            VStack(spacing: Spacing.md) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(AppColor.accent)

                Text("\(progress.completed) of \(progress.total)")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(Color(.label))

                // Reserve a line for the current title so the layout doesn't jump as
                // titles arrive. Two lines max — truncation here is cosmetic; the
                // full title is exposed to VoiceOver via the value above.
                Text(progress.currentTitle ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Importing podcasts")
            .accessibilityValue(statusValue)
            .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // Animate the bar's fill, but honor Reduce Motion — instant when reduced.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: progress.completed)
        .onAppear {
            // One announcement at the start. After this, progress is on-demand via
            // the accessibility value above; the final "Imported N podcasts" comes
            // from OPMLFileImporter when the import settles.
            Announcer.announce(
                String(localized: "Importing ^[\(progress.total) podcast](inflect: true)"),
                assertive: true
            )
        }
    }
}
