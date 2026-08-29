import SwiftUI

struct FeedRefreshSettingsView: View {
    @Environment(AppRuntime.self) private var runtime

    var body: some View {
        let snapshot = runtime.feedRefreshStatus.snapshot
        Form {
            Section("Latest refresh") {
                Text(summary(snapshot))
                    .accessibilityLabel(summary(snapshot))

                LabeledContent("Status", value: FeedRefreshStatusPresentation.status(snapshot.state))
                LabeledContent("Started", value: dateText(snapshot.startedAt))
                LabeledContent("Finished", value: dateText(snapshot.endedAt))
                LabeledContent("Last completed", value: dateText(snapshot.lastCompletedAt))
                if let lastSkippedAt = snapshot.lastSkippedAt,
                   let trigger = snapshot.lastSkippedTrigger {
                    LabeledContent(
                        "Last check skipped",
                        value: "\(dateText(lastSkippedAt)), \(FeedRefreshStatusPresentation.trigger(trigger)), refresh was already recent"
                    )
                }
                LabeledContent("Refresh type", value: FeedRefreshStatusPresentation.trigger(snapshot.trigger))
                LabeledContent("Podcasts checked", value: "\(snapshot.checked) of \(snapshot.total)")
                LabeledContent("New episodes", value: "\(snapshot.newEpisodes)")
                LabeledContent("Unchanged feeds", value: "\(snapshot.unchangedFeeds)")
                LabeledContent("Failed feeds", value: "\(snapshot.failedFeeds)")
            }

            Section("Background refresh") {
                Text(FeedRefreshStatusPresentation.scheduled(snapshot.scheduledAt) { dateText($0) })
                    .accessibilityLabel(
                        FeedRefreshStatusPresentation.scheduled(snapshot.scheduledAt) { dateText($0) }
                    )
                Text("iOS decides when Earshot runs in the background. A requested time is not a promised refresh time. Opening Earshot or using Refresh Library can start an eligible check sooner.")
                    .font(.footnote)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .navigationTitle("Feed Refresh")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summary(_ snapshot: FeedRefreshStatusSnapshot) -> String {
        FeedRefreshStatusPresentation.summary(snapshot) { dateText($0) }
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "Not available" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
