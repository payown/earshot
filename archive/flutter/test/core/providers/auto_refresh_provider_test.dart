import 'package:drift/native.dart';
import 'package:earshot/core/providers/auto_refresh_provider.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:earshot/features/subscriptions/data/podcast_repository.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockPodcastRepository extends Mock implements PodcastRepository {}

void main() {
  // autoRefreshProvider registers a WidgetsBindingObserver in build().
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late MockPodcastRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = MockPodcastRepository();
    when(() => repo.refreshAllFeeds()).thenAnswer((_) async {});
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        podcastRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  // Let the unawaited _refreshIfStale() future (which awaits a DB read) settle.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test('cold start does NOT refresh when the last refresh is recent', () async {
    await AppSettingsRepositoryImpl(
      database: db,
    ).setLastAutoRefreshAt(DateTime.now().toUtc());

    makeContainer().read(autoRefreshProvider);
    await settle();

    verifyNever(() => repo.refreshAllFeeds());
  });

  test(
    'cold start refreshes when there is no prior refresh timestamp',
    () async {
      makeContainer().read(autoRefreshProvider);
      await settle();

      verify(() => repo.refreshAllFeeds()).called(1);
    },
  );

  test('cold start refreshes when the last refresh is stale', () async {
    await AppSettingsRepositoryImpl(database: db).setLastAutoRefreshAt(
      DateTime.now().toUtc().subtract(const Duration(hours: 1)),
    );

    makeContainer().read(autoRefreshProvider);
    await settle();

    verify(() => repo.refreshAllFeeds()).called(1);
  });
}
