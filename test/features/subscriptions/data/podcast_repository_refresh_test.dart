import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/data/rss/parsed_feed.dart';
import 'package:earshot/data/rss/rss_parser.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
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

  void stubNetwork({List<ParsedEpisode> episodes = const []}) {
    when(() => dio.get<String>(any())).thenAnswer(
      (_) async => Response(
        data: '<rss/>',
        requestOptions: RequestOptions(path: _rssUrl),
        statusCode: 200,
      ),
    );
    when(() => parser.parse(any())).thenReturn(
      ParsedPodcast(
        title: 'Test Podcast',
        author: 'Author',
        episodes: episodes,
      ),
    );
  }

  Future<int> inboxCount(int podcastId) async {
    final rows =
        await (db.select(db.episodes)..where(
              (e) =>
                  e.podcastId.equals(podcastId) &
                  e.status.equals(EpisodeStatus.newEpisode.name) &
                  e.inboxDismissed.equals(false),
            ))
            .get();
    return rows.length;
  }

  // Regression test for commit 1846c22 (PR #165). Before fix, clearInbox()
  // set inboxDismissed=true but refresh then called
  // _setEpisodeDismissed(dismissed:false), flipping all cleared rows back.
  group('Clear Inbox persists across refresh', () {
    test('cleared episodes do not come back after refresh', () async {
      final ep = ParsedEpisode(
        guid: 'ep-1',
        title: 'Episode 1',
        audioUrl: 'https://example.com/ep1.mp3',
        pubDate: DateTime(2024, 1, 1).toUtc(),
      );
      stubNetwork(episodes: [ep]);
      final podcast = await repo.subscribe(_rssUrl);

      expect(await inboxCount(podcast.id), 1);

      await repo.clearInbox();
      expect(await inboxCount(podcast.id), 0);

      // Refresh with no new episodes — cleared rows must not come back.
      await repo.refreshFeed(podcast.id);
      expect(await inboxCount(podcast.id), 0);
    });

    test(
      'inbox stays empty after multiple refreshes following a clear',
      () async {
        final ep = ParsedEpisode(
          guid: 'ep-1',
          title: 'Episode 1',
          audioUrl: 'https://example.com/ep1.mp3',
          pubDate: DateTime(2024, 1, 1).toUtc(),
        );
        stubNetwork(episodes: [ep]);
        final podcast = await repo.subscribe(_rssUrl);

        await repo.clearInbox();
        expect(await inboxCount(podcast.id), 0);

        for (var i = 0; i < 3; i++) {
          await repo.refreshFeed(podcast.id);
          expect(await inboxCount(podcast.id), 0);
        }
      },
    );
  });

  group('Unstable GUID feeds do not re-flood inbox', () {
    test(
      'same episode with new GUID but stable pubDate stays backlog',
      () async {
        final pubDate = DateTime(2024, 5, 1).toUtc();
        stubNetwork(
          episodes: [
            ParsedEpisode(
              guid: 'ep-guid-v1',
              title: 'Braille Forum May',
              audioUrl: 'https://example.com/may.mp3',
              pubDate: pubDate,
            ),
          ],
        );
        final podcast = await repo.subscribe(_rssUrl);
        final countAfterSubscribe = await inboxCount(podcast.id);

        // Second fetch: same episode, new GUID (unstable GUID feed behaviour).
        stubNetwork(
          episodes: [
            ParsedEpisode(
              guid: 'ep-guid-v2',
              title: 'Braille Forum May',
              audioUrl: 'https://example.com/may.mp3',
              pubDate: pubDate,
            ),
          ],
        );
        await repo.refreshFeed(podcast.id);

        // Inbox count must not grow — the new-GUID row must be backlog.
        expect(await inboxCount(podcast.id), countAfterSubscribe);
      },
    );
  });

  group('Null pubDate items treated as backlog once a mark exists', () {
    test('null-pubDate item with new GUID is not added to inbox', () async {
      final pubDate = DateTime(2024, 5, 1).toUtc();
      stubNetwork(
        episodes: [
          ParsedEpisode(
            guid: 'ep-1',
            title: 'Known episode',
            audioUrl: 'https://example.com/ep1.mp3',
            pubDate: pubDate,
          ),
        ],
      );
      final podcast = await repo.subscribe(_rssUrl);

      await repo.clearInbox();
      expect(await inboxCount(podcast.id), 0);

      // Refresh with a new-GUID item that has no parseable pubDate.
      stubNetwork(
        episodes: [
          ParsedEpisode(
            guid: 'ep-1',
            title: 'Known episode',
            audioUrl: 'https://example.com/ep1.mp3',
            pubDate: pubDate,
          ),
          ParsedEpisode(
            guid: 'ep-ghost-${DateTime.now().millisecondsSinceEpoch}',
            title: 'Ghost episode (null pubDate)',
            audioUrl: 'https://example.com/ghost.mp3',
          ),
        ],
      );
      await repo.refreshFeed(podcast.id);

      // Ghost item must not appear in inbox.
      expect(await inboxCount(podcast.id), 0);
    });
  });

  group('Excluded podcast episodes still get dismissed on refresh', () {
    test('excluded podcast rows get inboxDismissed=true on refresh', () async {
      final ep = ParsedEpisode(
        guid: 'ep-1',
        title: 'Episode 1',
        audioUrl: 'https://example.com/ep1.mp3',
        pubDate: DateTime(2024, 5, 1).toUtc(),
      );
      stubNetwork(episodes: [ep]);
      final podcast = await repo.subscribe(_rssUrl);

      expect(await inboxCount(podcast.id), 1);

      // Exclude the podcast from inbox.
      await repo.setInboxExcluded(podcast.id, excluded: true);
      expect(await inboxCount(podcast.id), 0);

      // Refresh should keep the rows dismissed.
      await repo.refreshFeed(podcast.id);
      expect(await inboxCount(podcast.id), 0);
    });
  });

  group('dismissFromInbox', () {
    Future<EpisodeRow?> fetchEpisode(String guid) => (db.select(
      db.episodes,
    )..where((e) => e.guid.equals(guid))).getSingleOrNull();

    test(
      'sets inboxDismissed=true without changing status or playedAt',
      () async {
        final ep = ParsedEpisode(
          guid: 'ep-dismiss-1',
          title: 'Dismiss me',
          audioUrl: 'https://example.com/ep1.mp3',
          pubDate: DateTime(2024, 1, 1).toUtc(),
        );
        stubNetwork(episodes: [ep]);
        final podcast = await repo.subscribe(_rssUrl);

        final before = await fetchEpisode('ep-dismiss-1');
        expect(before?.inboxDismissed, false);
        expect(before?.status, EpisodeStatus.newEpisode);
        expect(before?.playedAt, null);

        await repo.dismissFromInbox(before!.id, alsoMarkPlayed: false);

        final after = await fetchEpisode('ep-dismiss-1');
        expect(
          after?.inboxDismissed,
          true,
          reason: 'must be dismissed from inbox',
        );
        expect(
          after?.status,
          EpisodeStatus.newEpisode,
          reason: 'status must not change when alsoMarkPlayed=false',
        );
        expect(
          after?.playedAt,
          null,
          reason: 'playedAt must not change when alsoMarkPlayed=false',
        );

        // Inbox count must drop to zero.
        expect(await inboxCount(podcast.id), 0);
      },
    );

    test(
      'sets inboxDismissed=true and marks played when alsoMarkPlayed=true',
      () async {
        final ep = ParsedEpisode(
          guid: 'ep-dismiss-2',
          title: 'Dismiss and mark played',
          audioUrl: 'https://example.com/ep2.mp3',
          pubDate: DateTime(2024, 2, 1).toUtc(),
        );
        stubNetwork(episodes: [ep]);
        await repo.subscribe(_rssUrl);

        final before = await fetchEpisode('ep-dismiss-2');
        await repo.dismissFromInbox(before!.id, alsoMarkPlayed: true);

        final after = await fetchEpisode('ep-dismiss-2');
        expect(
          after?.inboxDismissed,
          true,
          reason: 'must be dismissed from inbox',
        );
        expect(
          after?.status,
          EpisodeStatus.played,
          reason: 'status must be played when alsoMarkPlayed=true',
        );
        expect(
          after?.playedAt,
          isA<DateTime>(),
          reason: 'playedAt must be set when alsoMarkPlayed=true',
        );
      },
    );
  });

  group('Schema v12 migration SQL', () {
    test(
      'existing newEpisode rows at or before lastSeenPubDate get dismissed',
      () async {
        // Seed a podcast row with lastSeenPubDate and matching episode rows
        // that simulate the "stuck after v11" state.
        final mark = DateTime(2024, 5, 1).toUtc();

        final podcastId = await db
            .into(db.podcasts)
            .insert(
              PodcastsCompanion.insert(
                rssUrl: 'https://example.com/feed2.xml',
                title: 'Stale Podcast',
                lastSeenPubDate: Value(mark),
              ),
            );

        // Row that should be dismissed: pubDate <= mark.
        await db
            .into(db.episodes)
            .insert(
              EpisodesCompanion.insert(
                podcastId: podcastId,
                guid: 'stale-old',
                title: 'Old episode',
                audioUrl: 'https://example.com/old.mp3',
                pubDate: Value(DateTime(2024, 4, 1).toUtc()),
              ),
            );

        // Row that should be dismissed: null pubDate.
        await db
            .into(db.episodes)
            .insert(
              EpisodesCompanion.insert(
                podcastId: podcastId,
                guid: 'stale-null',
                title: 'No date episode',
                audioUrl: 'https://example.com/nodate.mp3',
              ),
            );

        // Row that must NOT be dismissed: pubDate > mark (genuinely new).
        await db
            .into(db.episodes)
            .insert(
              EpisodesCompanion.insert(
                podcastId: podcastId,
                guid: 'new-ep',
                title: 'New episode',
                audioUrl: 'https://example.com/new.mp3',
                pubDate: Value(DateTime(2024, 6, 1).toUtc()),
              ),
            );

        expect(await inboxCount(podcastId), 3);

        // Run the v12 migration SQL directly.
        await db.customStatement('''
        UPDATE episodes
        SET inbox_dismissed = 1
        WHERE status = 'newEpisode'
          AND (
            pub_date IS NULL
            OR pub_date <= (
              SELECT last_seen_pub_date FROM podcasts
              WHERE podcasts.id = episodes.podcast_id
            )
          )
          AND EXISTS (
            SELECT 1 FROM podcasts
            WHERE podcasts.id = episodes.podcast_id
              AND podcasts.last_seen_pub_date IS NOT NULL
          )
      ''');

        // Old and null rows dismissed; new row stays.
        expect(await inboxCount(podcastId), 1);
      },
    );
  });
}
