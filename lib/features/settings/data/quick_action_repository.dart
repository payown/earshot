import '../domain/quick_action_definition.dart';

abstract interface class QuickActionRepository {
  Future<List<EpisodeAction>> getEpisodeActions();

  Future<List<PodcastAction>> getPodcastActions();

  Future<void> saveEpisodeActions(List<EpisodeAction> actions);

  Future<void> savePodcastActions(List<PodcastAction> actions);
}
