import AVFoundation
import Flutter

/// Reads chapter markers from audio files using AVFoundation.
/// Works for both MP3 (ID3 CHAP frames) and M4A/AAC (QuickTime chapter tracks).
class ChapterChannel {
    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "media.payown.earshot/chapters",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            guard call.method == "getChapters" else {
                result(FlutterMethodNotImplemented)
                return
            }
            guard
                let args = call.arguments as? [String: Any],
                let urlString = args["url"] as? String,
                let url = URL(string: urlString)
            else {
                result([])
                return
            }
            ChapterChannel.fetchChapters(from: url, result: result)
        }
    }

    private static func fetchChapters(from url: URL, result: @escaping FlutterResult) {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
        ])

        asset.loadValuesAsynchronously(forKeys: ["availableChapterLocales"]) {
            let status = asset.statusOfValue(forKey: "availableChapterLocales", error: nil)
            guard status == .loaded else {
                DispatchQueue.main.async { result([]) }
                return
            }

            // Use preferred locales with an "und" (undetermined) fallback so
            // un-localised chapter tracks are always found.
            let locales = Locale.preferredLanguages + ["und", ""]
            let groups = asset.chapterMetadataGroups(
                bestMatchingPreferredLanguages: locales
            )

            let chapters: [[String: Any]] = groups.compactMap { group in
                let startSeconds = CMTimeGetSeconds(group.timeRange.start)
                guard startSeconds.isFinite, startSeconds >= 0 else { return nil }

                let titleItems = AVMetadataItem.metadataItems(
                    from: group.items,
                    filteredByIdentifier: .commonIdentifierTitle
                )
                let title = titleItems.first?.stringValue ?? ""

                return ["startTime": startSeconds, "title": title]
            }

            DispatchQueue.main.async { result(chapters) }
        }
    }
}
