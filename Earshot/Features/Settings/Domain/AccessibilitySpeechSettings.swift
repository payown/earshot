import Foundation

enum SpokenDescriptionMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case brief
    case full

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// Immutable row-speech choices captured at a list boundary and passed to the
/// pure composers. Interaction-critical state remains mandatory.
struct EpisodeSpokenDetails: Equatable, Sendable {
    var includesPodcastName = true
    var includesPublishedDate = true
    var includesDownloadStatus = true
    var includesDuration = true
    var descriptionMode: SpokenDescriptionMode = .brief
}
