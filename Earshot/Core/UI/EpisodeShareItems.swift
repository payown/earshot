import Foundation
import LinkPresentation
import UIKit
import UniformTypeIdentifiers

/// A single URL is the payload for URL-consuming share extensions and Shortcuts.
/// Keep the title in metadata rather than as a second, unrelated input item.
@MainActor
enum EpisodeShareItems {
    static func make(title: String, audioURL: String) -> [Any] {
        let value = audioURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return [title] }
        return [EpisodeLinkShareItem(title: title, url: url)]
    }
}

/// Immutable values also satisfy UIKit's nonisolated item-source callbacks.
final class EpisodeLinkShareItem: NSObject, UIActivityItemSource {
    private let title: String
    private let url: URL

    init(title: String, url: URL) {
        self.title = title
        self.url = url
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        title
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.url.identifier
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url
        metadata.url = url
        return metadata
    }
}
