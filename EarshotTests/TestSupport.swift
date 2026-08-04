import SwiftData
@testable import Earshot

/// Shared SwiftData test store. Rapidly creating many in-memory `ModelContainer`s
/// for the same schema within one test process is unreliable, so the whole test
/// target shares a single in-memory container and wipes it between tests for
/// isolation.
@MainActor
enum TestStore {
    static let container: ModelContainer = {
        // A single container for the entire test run.
        try! ModelContainerFactory.makeInMemory()
    }()

    /// Returns the shared context after removing all persisted objects, so each
    /// test starts from an empty store.
    static func freshContext() -> ModelContext {
        LocalRuntimeState.shared.clear()
        let ctx = container.mainContext
        wipe(ctx, Podcast.self)
        wipe(ctx, Episode.self)
        wipe(ctx, QueueItem.self)
        wipe(ctx, ListeningSession.self)
        wipe(ctx, Bookmark.self)
        wipe(ctx, PodcastFolder.self)
        wipe(ctx, FolderMembership.self)
        wipe(ctx, EpisodeFolderMembership.self)
        wipe(ctx, RecentlyExpired.self)
        wipe(ctx, QuickActionConfig.self)
        wipe(ctx, AppSetting.self)
        wipe(ctx, LocalPodcastState.self)
        wipe(ctx, LocalEpisodeState.self)
        wipe(ctx, LocalAppSetting.self)
        try? ctx.save()
        return ctx
    }

    private static func wipe<T: PersistentModel>(_ ctx: ModelContext, _ type: T.Type) {
        for object in (try? ctx.fetch(FetchDescriptor<T>())) ?? [] {
            ctx.delete(object)
        }
    }
}
