import 'package:earshot/core/episode_action_builder.dart';
import 'package:earshot/features/player/data/audio_handler.dart';
import 'package:earshot/features/player/data/queue_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAudioHandler extends Mock implements EarshotAudioHandler {}

class MockQueueRepository extends Mock implements QueueRepository {}

void main() {
  late MockAudioHandler handler;
  late MockQueueRepository queueRepo;

  setUp(() {
    handler = MockAudioHandler();
    queueRepo = MockQueueRepository();
    when(() => handler.markCurrentEpisodePlayed()).thenAnswer((_) async {});
    when(() => queueRepo.cancelFromQueue(any())).thenAnswer((_) async {});
  });

  test(
    'removing the currently-playing episode marks it played and advances',
    () async {
      final markedPlayed = await removeEpisodeFromQueue(
        episodeId: 7,
        currentEpisodeId: 7,
        handler: handler,
        queueRepo: queueRepo,
      );

      expect(markedPlayed, isTrue);
      verify(() => handler.markCurrentEpisodePlayed()).called(1);
      verifyNever(() => queueRepo.cancelFromQueue(any()));
    },
  );

  test('removing a non-playing episode cancels it from the queue', () async {
    final markedPlayed = await removeEpisodeFromQueue(
      episodeId: 7,
      currentEpisodeId: 99,
      handler: handler,
      queueRepo: queueRepo,
    );

    expect(markedPlayed, isFalse);
    verify(() => queueRepo.cancelFromQueue(7)).called(1);
    verifyNever(() => handler.markCurrentEpisodePlayed());
  });

  test('removing with nothing playing cancels from the queue', () async {
    final markedPlayed = await removeEpisodeFromQueue(
      episodeId: 7,
      currentEpisodeId: null,
      handler: handler,
      queueRepo: queueRepo,
    );

    expect(markedPlayed, isFalse);
    verify(() => queueRepo.cancelFromQueue(7)).called(1);
    verifyNever(() => handler.markCurrentEpisodePlayed());
  });
}
