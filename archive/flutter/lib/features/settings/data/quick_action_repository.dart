import '../domain/quick_action_definition.dart';

abstract interface class QuickActionRepository {
  Stream<List<EpisodeAction>> watchEpisodeActions();

  Stream<List<PodcastAction>> watchPodcastActions();

  Future<void> saveEpisodeActions(List<EpisodeAction> actions);

  Future<void> savePodcastActions(List<PodcastAction> actions);
}
