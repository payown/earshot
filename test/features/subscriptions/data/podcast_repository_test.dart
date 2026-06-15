import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/data/rss/parsed_feed.dart';
import 'package:earshot/data/rss/rss_parser.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
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
    repo = PodcastRepositoryImpl(
      database: db,
      dio: dio,
      rssParser: parser,
      settings: AppSettingsRepositoryImpl(database: db),
    );
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

  const sampleEpisode = ParsedEpisode(
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

  group('refreshAllFeeds', () {
    test('processes feeds in case-insensitive alphabetical order', () async {
      // Subscribe two feeds in reverse alphabetical order.
      const zebraUrl = 'https://example.com/zebra.xml';
      const alphaUrl = 'https://example.com/alpha.xml';

      when(() => dio.get<String>(zebraUrl)).thenAnswer(
        (_) async => Response(
          data: '<rss/>',
          requestOptions: RequestOptions(path: zebraUrl),
          statusCode: 200,
        ),
      );
      when(() => parser.parse(any())).thenReturn(
        const ParsedPodcast(title: 'zebra cast', episodes: []),
      );
      await repo.subscribe(zebraUrl);

      when(() => dio.get<String>(alphaUrl)).thenAnswer(
        (_) async => Response(
          data: '<rss/>',
          requestOptions: RequestOptions(path: alphaUrl),
          statusCode: 200,
        ),
      );
      when(() => parser.parse(any())).thenReturn(
        const ParsedPodcast(title: 'Alpha Cast', episodes: []),
      );
      await repo.subscribe(alphaUrl);

      // Track the order URLs are fetched during refreshAllFeeds.
      final fetchOrder = <String>[];
      when(() => dio.get<String>(any())).thenAnswer((invocation) async {
        fetchOrder.add(invocation.positionalArguments.first as String);
        return Response(
          data: '<rss/>',
          requestOptions: RequestOptions(
            path: invocation.positionalArguments.first as String,
          ),
          statusCode: 200,
        );
      });
      when(() => parser.parse(any())).thenReturn(
        const ParsedPodcast(title: 'irrelevant', episodes: []),
      );

      await repo.refreshAllFeeds();

      expect(fetchOrder, [alphaUrl, zebraUrl]);
    });

    test(
      'emits a single batch audit event after all feeds are refreshed',
      () async {
        stubFeed(episodes: [sampleEpisode]);
        await repo.subscribe(_rssUrl);
        when(() => parser.parse(any())).thenReturn(
          const ParsedPodcast(title: 'Test Podcast', episodes: [sampleEpisode]),
        );

        // Subscribe before calling refreshAllFeeds so the listener is in place
        // when the event fires at the end of the batch.
        final eventFuture = repo.feedRefreshAuditEvents.first;
        await repo.refreshAllFeeds();
        expect(await eventFuture, startsWith('All feeds checked at '));
      },
    );
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

      const ep2 = ParsedEpisode(
        guid: 'ep-2',
        title: 'Episode 2',
        audioUrl: 'https://example.com/ep2.mp3',
      );
      when(() => parser.parse(any())).thenReturn(
        const ParsedPodcast(
          title: 'Test Podcast',
          episodes: [sampleEpisode, ep2],
        ),
      );
      await repo.refreshFeed(podcast.id);

      final episodes = await repo.watchEpisodes(podcast.id).first;
      expect(episodes.length, 2);
    });

    test('does nothing for unknown podcast id', () async {
      await repo.refreshFeed(999);
    });

    test('inserts new GUID with downloadStatus none', () async {
      stubFeed(episodes: []);
      final podcast = await repo.subscribe(_rssUrl);

      const newEp = ParsedEpisode(
        guid: 'brand-new-guid',
        title: 'New Episode',
        audioUrl: 'https://example.com/new.mp3',
      );
      when(() => parser.parse(any())).thenReturn(
        const ParsedPodcast(title: 'Test Podcast', episodes: [newEp]),
      );
      await repo.refreshFeed(podcast.id);

      final episodes = await repo.watchEpisodes(podcast.id).first;
      expect(episodes.length, 1);
      expect(episodes.first.guid, 'brand-new-guid');
      expect(
        episodes.first.downloadStatus,
        equals(DownloadStatus.none),
      );
    });

    test('does not duplicate episode when GUID already exists', () async {
      stubFeed(episodes: [sampleEpisode]);
      final podcast = await repo.subscribe(_rssUrl);

      when(() => parser.parse(any())).thenReturn(
        const ParsedPodcast(title: 'Test Podcast', episodes: [sampleEpisode]),
      );
      await repo.refreshFeed(podcast.id);

      final episodes = await repo.watchEpisodes(podcast.id).first;
      expect(episodes.length, 1);
    });

    test(
      'future-dated episode does not advance the high-water mark (#296)',
      () async {
        stubFeed(episodes: []);
        final podcast = await repo.subscribe(_rssUrl);
        final now = DateTime.now().toUtc();

        final normalOld = ParsedEpisode(
          guid: 'normal-old',
          title: 'Normal old',
          audioUrl: 'https://example.com/old.mp3',
          pubDate: now.subtract(const Duration(days: 2)),
        );
        final future = ParsedEpisode(
          guid: 'future',
          title: 'Future dated',
          audioUrl: 'https://example.com/future.mp3',
          pubDate: now.add(const Duration(days: 30)),
        );
        when(() => parser.parse(any())).thenReturn(
          ParsedPodcast(title: 'Test Podcast', episodes: [normalOld, future]),
        );
        await repo.refreshFeed(podcast.id);

        final row = await (db.select(
          db.podcasts,
        )..where((p) => p.id.equals(podcast.id))).getSingle();
        expect(row.lastSeenPubDate, isNotNull);
        expect(
          row.lastSeenPubDate!.isAfter(now),
          isFalse,
          reason: 'a future-dated episode must not push the mark ahead of now',
        );
      },
    );

    test(
      'new episode still reaches the inbox after a future-dated item (#296)',
      () async {
        final now = DateTime.now().toUtc();
        final normalOld = ParsedEpisode(
          guid: 'normal-old',
          title: 'Normal old',
          audioUrl: 'https://example.com/old.mp3',
          pubDate: now.subtract(const Duration(days: 2)),
        );
        final future = ParsedEpisode(
          guid: 'future',
          title: 'Future dated',
          audioUrl: 'https://example.com/future.mp3',
          pubDate: now.add(const Duration(days: 30)),
        );

        // Subscribe with a real past episode so the mark seeds to now - 2d.
        stubFeed(episodes: [normalOld]);
        final podcast = await repo.subscribe(_rssUrl);

        // Refresh #1 introduces the future-dated item. Without the fix this
        // poisons the mark (advancing it to now + 30d); with the fix the mark
        // stays at the newest non-future date (now - 2d).
        when(() => parser.parse(any())).thenReturn(
          ParsedPodcast(title: 'Test Podcast', episodes: [normalOld, future]),
        );
        await repo.refreshFeed(podcast.id);

        // Refresh #2 brings a genuinely new, correctly-dated episode. It must
        // reach the inbox rather than being suppressed as backlog by a poisoned
        // future mark.
        final normalNew = ParsedEpisode(
          guid: 'normal-new',
          title: 'Normal new',
          audioUrl: 'https://example.com/new.mp3',
          pubDate: now.subtract(const Duration(hours: 1)),
        );
        when(() => parser.parse(any())).thenReturn(
          ParsedPodcast(
            title: 'Test Podcast',
            episodes: [normalOld, future, normalNew],
          ),
        );
        await repo.refreshFeed(podcast.id);

        final newRow = await (db.select(
          db.episodes,
        )..where((e) => e.guid.equals('normal-new'))).getSingle();
        expect(newRow.status, EpisodeStatus.newEpisode);
        expect(
          newRow.inboxDismissed,
          isFalse,
          reason: 'the new episode must not be suppressed as backlog',
        );
      },
    );

    test(
      'refresh clamps an already-future high-water mark back to now (#296)',
      () async {
        stubFeed(episodes: []);
        final podcast = await repo.subscribe(_rssUrl);
        final now = DateTime.now().toUtc();

        // Simulate a podcast poisoned before the fix: mark sits in the future.
        await (db.update(
          db.podcasts,
        )..where((p) => p.id.equals(podcast.id))).write(
          PodcastsCompanion(
            lastSeenPubDate: Value(now.add(const Duration(days: 30))),
          ),
        );

        final normal = ParsedEpisode(
          guid: 'normal',
          title: 'Normal',
          audioUrl: 'https://example.com/normal.mp3',
          pubDate: now.subtract(const Duration(hours: 1)),
        );
        when(() => parser.parse(any())).thenReturn(
          ParsedPodcast(title: 'Test Podcast', episodes: [normal]),
        );
        await repo.refreshFeed(podcast.id);

        final row = await (db.select(
          db.podcasts,
        )..where((p) => p.id.equals(podcast.id))).getSingle();
        expect(
          row.lastSeenPubDate!.isAfter(now),
          isFalse,
          reason: 'a future mark must be clamped back to now on refresh',
        );
      },
    );

    test(
      'preserves downloadStatus on refresh when GUID already exists',
      () async {
        stubFeed(episodes: [sampleEpisode]);
        final podcast = await repo.subscribe(_rssUrl);

        final before = (await repo.watchEpisodes(podcast.id).first).first;
        expect(before.downloadStatus, DownloadStatus.none);

        when(() => parser.parse(any())).thenReturn(
          const ParsedPodcast(title: 'Test Podcast', episodes: [sampleEpisode]),
        );
        await repo.refreshFeed(podcast.id);

        final after = (await repo.watchEpisodes(podcast.id).first).first;
        expect(after.downloadStatus, DownloadStatus.none);
      },
    );

    test(
      'leaves DB episode intact when GUID is absent from refreshed feed',
      () async {
        stubFeed(
          episodes: [
            sampleEpisode,
            const ParsedEpisode(
              guid: 'ep-to-disappear',
              title: 'Old Episode',
              audioUrl: 'https://example.com/old.mp3',
            ),
          ],
        );
        final podcast = await repo.subscribe(_rssUrl);

        when(() => parser.parse(any())).thenReturn(
          const ParsedPodcast(title: 'Test Podcast', episodes: [sampleEpisode]),
        );
        await repo.refreshFeed(podcast.id);

        final episodes = await repo.watchEpisodes(podcast.id).first;
        expect(episodes.length, 2);
        expect(
          episodes.map((e) => e.guid),
          containsAll(['ep-1', 'ep-to-disappear']),
        );
      },
    );

    test(
      'inserts new GUID with pubDate before high-water mark as played+dismissed',
      () async {
        final anchor = DateTime(2024, 6, 1, 12);
        stubFeed(
          episodes: [
            ParsedEpisode(
              guid: 'old-guid',
              title: 'Old Episode',
              audioUrl: 'https://example.com/old.mp3',
              pubDate: anchor,
            ),
          ],
        );
        final podcast = await repo.subscribe(_rssUrl);

        // Second refresh: a new GUID but an older publish date.
        const backlogGuid = 'backlog-guid';
        when(() => parser.parse(any())).thenReturn(
          ParsedPodcast(
            title: 'Test Podcast',
            episodes: [
              ParsedEpisode(
                guid: backlogGuid,
                title: 'Backlog Episode',
                audioUrl: 'https://example.com/backlog.mp3',
                pubDate: DateTime(2024, 5, 1), // before anchor
              ),
            ],
          ),
        );
        await repo.refreshFeed(podcast.id);

        // Check the raw DB row — Episode domain model doesn't expose inboxDismissed.
        final row = await (db.select(
          db.episodes,
        )..where((e) => e.guid.equals(backlogGuid))).getSingle();
        expect(row.status, EpisodeStatus.played);
        expect(row.inboxDismissed, isTrue);
      },
    );

    test(
      'inserts new GUID with pubDate after high-water mark as newEpisode',
      () async {
        final anchor = DateTime(2024, 6, 1, 12);
        stubFeed(
          episodes: [
            ParsedEpisode(
              guid: 'old-guid',
              title: 'Old Episode',
              audioUrl: 'https://example.com/old.mp3',
              pubDate: anchor,
            ),
          ],
        );
        final podcast = await repo.subscribe(_rssUrl);

        // Second refresh: a new GUID with a newer publish date.
        const freshGuid = 'fresh-guid';
        when(() => parser.parse(any())).thenReturn(
          ParsedPodcast(
            title: 'Test Podcast',
            episodes: [
              ParsedEpisode(
                guid: freshGuid,
                title: 'Fresh Episode',
                audioUrl: 'https://example.com/fresh.mp3',
                pubDate: anchor.add(const Duration(days: 1)),
              ),
            ],
          ),
        );
        await repo.refreshFeed(podcast.id);

        final row = await (db.select(
          db.episodes,
        )..where((e) => e.guid.equals(freshGuid))).getSingle();
        expect(row.status, EpisodeStatus.newEpisode);
        expect(row.inboxDismissed, isFalse);
      },
    );
  });
}
