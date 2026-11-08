import Foundation
import WidgetKit

enum WatchWidgetSnapshot {
    private static let group = "group.media.payown.earshot.watch"

    static func save(title: String?, playing: Bool) {
        guard let defaults = UserDefaults(suiteName: group) else { return }
        defaults.set(title, forKey: "episodeTitle")
        defaults.set(playing, forKey: "isPlaying")
        defaults.set(Date.now, forKey: "updatedAt")
        WidgetCenter.shared.reloadAllTimelines()
    }
}
