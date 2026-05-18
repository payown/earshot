import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/rss/parsed_feed.dart';
import 'package:earshot/data/rss/rss_parser.dart';
import 'package:earshot/features/subscriptions/data/podcast_exception.dart';
import 'package:earshot/features/subscriptions/data/podcast_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

class MockRssParser extends Mock implements RssParser {}

const _rssUrl = 'https://example.com/feed.xml';

void main() {
  late AppDatabase db;
  late MockDio dio;
  late MockRssParser parser;
  late PodcastRepositoryImpl repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dio = MockDio();
    parser = MockRssParser();
    repo = PodcastRepositoryImpl(database: db, dio: dio, rssParser: parser);
  });

  tearDown(() => db.close());

  void stubFeed({
    String title = 'Test Podcast',
    String? author = 'Jane Smith',
    List<ParsedEpisode> episodes = const [],
  }) {
    when(() => dio.get<String>(any())).thenAnswer(
      (_) async => Response(
        data: '<rss/>',
        requestOptions: RequestOptions(path: _rssUrl),
        statusCode: 200,
      ),
    );
    when(() => parser.parse(any())).thenReturn(
      ParsedPodcast(title: title, author: author, episodes: episodes),
    );
  }

  final sampleEpisode = ParsedEpisode(
    guid: 'ep-1',
    title: 'Episode 1',
    audioUrl: 'https://example.com/ep1.mp3',
    durationSeconds: 3600,
  );

  group('subscribe', () {
    test('returns podcast on success', () async {
      stubFeed(episodes: [sampleEpisode]);
      final podcast = await repo.subscribe(_rssUrl);
      expect(podcast.title, 'Test Podcast');
      expect(podcast.author, 'Jane Smith');
      expect(podcast.rssUrl, _rssUrl);
    });

    test('inserts episodes', () async {
      stubFeed(episodes: [sampleEpisode]);
      final podcast = await repo.subscribe(_rssUrl);
      final episodes = await repo.watchEpisodes(podcast.id).first;
      expect(episodes.length, 1);
      expect(episodes.first.guid, 'ep-1');
    });

    test('throws PodcastAlreadySubscribedException on duplicate', () async {
      stubFeed();
      await repo.subscribe(_rssUrl);
      expect(
        () => repo.subscribe(_rssUrl),
        throwsA(isA<PodcastAlreadySubscribedException>()),
      );
    });

    test('throws PodcastFetchException on network error', () async {
      when(() => dio.get<String>(any())).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: _rssUrl),
          message: 'Connection refused',
        ),
      );
      expect(
        () => repo.subscribe(_rssUrl),
        throwsA(isA<PodcastFetchException>()),
      );
    });

    test('throws PodcastNotFoundException on parse failure', () async {
      when(() => dio.get<String>(any())).thenAnswer(
        (_) async => Response(
          data: '<rss/>',
          requestOptions: RequestOptions(path: _rssUrl),
          statusCode: 200,
        ),
      );
      when(
        () => parser.parse(any()),
      ).thenThrow(const RssParseException('bad xml'));
      expect(
        () => repo.subscribe(_rssUrl),
        throwsA(isA<PodcastNotFoundException>()),
      );
    });
  });

  group('unsubscribe', () {
    test('removes podcast and cascades episodes', () async {
      stubFeed(episodes: [sampleEpisode]);
      final podcast = await repo.subscribe(_rssUrl);
      await repo.unsubscribe(podcast.id);
      final subscriptions = await repo.watchSubscriptions().first;
      expect(subscriptions, isEmpty);
      final episodes = await repo.watchEpisodes(podcast.id).first;
      expect(episodes, isEmpty);
    });
  });

  group('watchSubscriptions', () {
    test('emits empty list initially', () async {
      expect(await repo.watchSubscriptions().first, isEmpty);
    });

    test('emits updated list after subscribe', () async {
      stubFeed();
      await repo.subscribe(_rssUrl);
      final list = await repo.watchSubscriptions().first;
      expect(list.length, 1);
      expect(list.first.title, 'Test Podcast');
    });

    test('orders by title alphabetically', () async {
      stubFeed(title: 'Zebra Cast');
      await repo.subscribe(_rssUrl);

      const url2 = 'https://example.com/feed2.xml';
      when(() => dio.get<String>(url2)).thenAnswer(
        (_) async => Response(
          data: '<rss/>',
          requestOptions: RequestOptions(path: url2),
          statusCode: 200,
        ),
      );
      when(() => parser.parse(any())).thenReturn(
        const ParsedPodcast(title: 'Alpha Cast', episodes: []),
      );
      await repo.subscribe(url2);

      final list = await repo.watchSubscriptions().first;
      expect(list[0].title, 'Alpha Cast');
      expect(list[1].title, 'Zebra Cast');
    });
  });

  group('refreshFeed', () {
    test('updates podcast metadata', () async {
      stubFeed(title: 'Old Title');
      final podcast = await repo.subscribe(_rssUrl);

      when(() => parser.parse(any())).thenReturn(
        const ParsedPodcast(title: 'New Title', episodes: []),
      );
      await repo.refreshFeed(podcast.id);

      final updated = await repo.watchSubscriptions().first;
      expect(updated.first.title, 'New Title');
    });

    test('inserts new episodes without removing existing', () async {
      stubFeed(episodes: [sampleEpisode]);
      final podcast = await repo.subscribe(_rssUrl);

      final ep2 = ParsedEpisode(
        guid: 'ep-2',
        title: 'Episode 2',
        audioUrl: 'https://example.com/ep2.mp3',
      );
      when(() => parser.parse(any())).thenReturn(
        ParsedPodcast(title: 'Test Podcast', episodes: [sampleEpisode, ep2]),
      );
      await repo.refreshFeed(podcast.id);

      final episodes = await repo.watchEpisodes(podcast.id).first;
      expect(episodes.length, 2);
    });

    test('does nothing for unknown podcast id', () async {
      await repo.refreshFeed(999);
    });
  });
}
