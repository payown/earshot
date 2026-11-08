import Foundation
import WidgetKit

enum WatchWidgetSnapshot {
    private static let group = "group.media.payown.earshot.watch"

    static func shouldReload(changed: Bool, previousUpdate: Date?, now: Date) -> Bool {
        changed || (previousUpdate.map { now.timeIntervalSince($0) >= 24 * 60 * 60 } ?? true)
    }

    static func save(title: String?, playing: Bool) {
        guard let defaults = UserDefaults(suiteName: group) else { return }
        let changed = defaults.string(forKey: "episodeTitle") != title || defaults.bool(forKey: "isPlaying") != playing
        let now = Date.now
        let previousUpdate = defaults.object(forKey: "updatedAt") as? Date
        if changed {
            defaults.set(title, forKey: "episodeTitle")
            defaults.set(playing, forKey: "isPlaying")
        }
        defaults.set(now, forKey: "updatedAt")
        if shouldReload(changed: changed, previousUpdate: previousUpdate, now: now) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
