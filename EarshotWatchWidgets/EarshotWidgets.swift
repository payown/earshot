import SwiftUI
import WidgetKit

struct EarshotWidgetEntry: TimelineEntry {
    let date: Date
    let title: String?
    let isPlaying: Bool
}

struct EarshotWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> EarshotWidgetEntry {
        .init(date: .now, title: "Earshot", isPlaying: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (EarshotWidgetEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EarshotWidgetEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(60 * 60))))
    }

    private func entry() -> EarshotWidgetEntry {
        let defaults = UserDefaults(suiteName: "group.media.payown.earshot.watch")
        let updatedAt = defaults?.object(forKey: "updatedAt") as? Date
        let valid = updatedAt.map { Date.now.timeIntervalSince($0) < 24 * 60 * 60 } ?? false
        return EarshotWidgetEntry(date: .now,
                                  title: valid ? defaults?.string(forKey: "episodeTitle") : nil,
                                  isPlaying: valid ? (defaults?.bool(forKey: "isPlaying") ?? false) : false)
    }
}

struct EarshotAccessoryWidget: Widget {
    let kind = "EarshotAccessory"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EarshotWidgetProvider()) { entry in
            VStack {
                Image(systemName: entry.isPlaying ? "play.fill" : "headphones")
                    .accessibilityHidden(true)
                Text(entry.title ?? "Earshot")
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.title.map { "Earshot, \($0)" } ?? "Open Earshot")
            .widgetURL(URL(string: "earshot-watch://now-playing"))
        }
        .configurationDisplayName("Continue Listening")
        .description("Open Earshot's Now Playing screen")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct EarshotWatchWidgetBundle: WidgetBundle {
    var body: some Widget { EarshotAccessoryWidget() }
}
