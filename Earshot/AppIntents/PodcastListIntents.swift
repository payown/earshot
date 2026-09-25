import AppIntents
import Foundation

struct GetFollowedPodcastsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Followed Podcasts from Earshot"
    static let description = IntentDescription("Returns the podcasts in Earshot’s bounded Siri/Search library, with titles and descriptions. Requires Include library in Siri and Search.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[PodcastEntity]> {
        guard LibrarySearchIndex.isEnabled else { throw LibraryPlaybackError.searchDisabled }
        _ = try await LibraryPlaybackBridge.shared.preparedRuntime()
        return .result(value: try await LibraryIntentBridge.shared.content().filter { $0.guid == nil }.map(PodcastEntity.init))
    }
}

struct PodcastCategoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast category")
    static let defaultQuery = PodcastCategoryQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}
struct PodcastCategoryQuery: EntityStringQuery {
    private var all: [PodcastCategoryEntity] {
        ApplePodcastCategories.all.flatMap { [$0] + $0.subcategories }.map { .init(id: $0.id, name: $0.name) }
    }
    func entities(for identifiers: [String]) async throws -> [PodcastCategoryEntity] { all.filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [PodcastCategoryEntity] { all.filter { $0.name.localizedStandardContains(string) } }
    func suggestedEntities() async throws -> [PodcastCategoryEntity] { all }
}

struct GetCategoryPodcastsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Podcasts by Category in Earshot"
    static let description = IntentDescription("Returns public chart podcasts for a category. Combine with Choose from List and Play or Queue a Directory Podcast. Uses your current storefront and does not follow shows.")
    @Parameter(title: "Category") var category: PodcastCategoryEntity
    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$category) podcasts in Earshot") }
    func perform() async throws -> some IntentResult & ReturnsValue<[DirectoryPodcastEntity]> {
        guard case let .results(results) = await ApplePodcastCategoryService().topPodcasts(
            categoryID: category.id, storefront: ApplePodcastCategoryService.storefront(), limit: 25
        ) else { throw ShortcutControlError(message: "Could not load category podcasts. Try again later.") }
        try Task.checkCancellation()
        return .result(value: results.map(DirectoryPodcastEntity.init))
    }
}

enum SavedPodcastEpisodeChoice: String, AppEnum {
    case queueFirst, newest, oldest
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Podcast episode choice")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .queueFirst: "Queue first, then newest unheard", .newest: "Newest unheard", .oldest: "Oldest unheard"
    ]
}
struct PlayUnheardPodcastIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play an Unheard Podcast Episode in Earshot"
    static let description = IntentDescription("Chooses an unheard episode already stored for a followed podcast. Queue first prefers a queued episode, then the newest stored unheard episode. Does not fetch missing publisher history.")
    @Parameter(title: "Podcast") var podcast: PodcastEntity
    @Parameter(title: "Action", default: .play) var action: DirectoryEpisodeAction
    @Parameter(title: "Choose", default: .queueFirst) var choice: SavedPodcastEpisodeChoice
    static var parameterSummary: some ParameterSummary { Summary("\(\.$action) \(\.$choice) from \(\.$podcast)") }
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.playUnheard(showID: podcast.id, choice: choice, action: action)
        return .result()
    }
}
