import 'dart:async';

import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/core/router/app_router.dart';
import 'package:earshot/core/sharing/shared_file_provider.dart';
import 'package:earshot/core/sharing/sharing_intent_gateway.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeGateway implements SharingIntentGateway {
  @override
  Future<List<String>> getInitialSharedFiles() async => const [];

  @override
  Stream<List<String>> get sharedFileStream => const Stream.empty();
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await AppSettingsRepositoryImpl(
      database: db,
    ).setOnboardingComplete(complete: true);
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharingIntentGatewayProvider.overrideWithValue(_FakeGateway()),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> pumpRouter(WidgetTester tester) async {
    final router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    // Let the onboarding check resolve and the /loading redirect settle.
    await tester.pumpAndSettle();
    // If a shared file is pending, OpmlImportScreen schedules an
    // announcement delay timer on entry; advance past it so it fires
    // before the widget tree is torn down.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  String currentLocation() => container
      .read(appRouterProvider)
      .routerDelegate
      .currentConfiguration
      .uri
      .toString();

  group(
    'malformed deep links land on fallback screens instead of throwing',
    () {
      testWidgets('/subscriptions/<non-numeric id> falls back to library', (
        tester,
      ) async {
        await pumpRouter(tester);

        container.read(appRouterProvider).go('/subscriptions/abc');
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(currentLocation(), AppRoutes.subscriptions);
      });

      testWidgets('/subscriptions/folders/<non-numeric id> falls back to '
          'library', (tester) async {
        await pumpRouter(tester);

        container.read(appRouterProvider).go('/subscriptions/folders/xyz');
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(currentLocation(), AppRoutes.subscriptions);
      });

      testWidgets(
        '/subscriptions/<non-numeric>/settings falls back to library',
        (
          tester,
        ) async {
          await pumpRouter(tester);

          container.read(appRouterProvider).go('/subscriptions/abc/settings');
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(currentLocation(), AppRoutes.subscriptions);
        },
      );

      testWidgets('/settings/quick-actions/<unknown type> falls back to the '
          'quick actions menu', (tester) async {
        await pumpRouter(tester);

        container.read(appRouterProvider).go('/settings/quick-actions/bogus');
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(currentLocation(), AppRoutes.settingsQuickActionsMenu);
      });

      testWidgets('/search/result without extra falls back to search', (
        tester,
      ) async {
        await pumpRouter(tester);

        container.read(appRouterProvider).go(AppRoutes.searchResult);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(currentLocation(), AppRoutes.search);
      });

      testWidgets('valid numeric podcast id still resolves', (tester) async {
        await pumpRouter(tester);

        container.read(appRouterProvider).go('/subscriptions/1');
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(currentLocation(), '/subscriptions/1');
      });

      testWidgets('valid quick-actions type still resolves', (tester) async {
        await pumpRouter(tester);

        container.read(appRouterProvider).go('/settings/quick-actions/episode');
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(currentLocation(), '/settings/quick-actions/episode');
      });
    },
  );

  group('default launch screen', () {
    testWidgets('defaults to library when no preference is set', (
      tester,
    ) async {
      await pumpRouter(tester);

      expect(currentLocation(), AppRoutes.subscriptions);
    });

    testWidgets('launches to inbox when set to inbox', (tester) async {
      await AppSettingsRepositoryImpl(
        database: db,
      ).setDefaultLaunchScreen(LaunchScreen.inbox);

      await pumpRouter(tester);

      expect(currentLocation(), AppRoutes.inbox);
    });

    testWidgets('launches to queue when set to queue', (tester) async {
      await AppSettingsRepositoryImpl(
        database: db,
      ).setDefaultLaunchScreen(LaunchScreen.queue);

      await pumpRouter(tester);

      expect(currentLocation(), AppRoutes.queue);
    });

    testWidgets('launches to downloads when set to downloads', (
      tester,
    ) async {
      await AppSettingsRepositoryImpl(
        database: db,
      ).setDefaultLaunchScreen(LaunchScreen.downloads);

      await pumpRouter(tester);

      expect(currentLocation(), AppRoutes.downloads);
    });
  });

  group('pending shared OPML file', () {
    ProviderContainer containerWithPendingShare() => ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharingIntentGatewayProvider.overrideWithValue(_FakeGateway()),
        initialSharedOpmlPathsProvider.overrideWithValue(['shared.opml']),
      ],
    );

    testWidgets('redirects from the default launch route to import-opml', (
      tester,
    ) async {
      container.dispose();
      container = containerWithPendingShare();

      await pumpRouter(tester);

      expect(currentLocation(), AppRoutes.settingsImportOpml);
    });

    testWidgets('redirects even when onboarding is incomplete', (
      tester,
    ) async {
      await AppSettingsRepositoryImpl(
        database: db,
      ).setOnboardingComplete(complete: false);
      container.dispose();
      container = containerWithPendingShare();

      await pumpRouter(tester);

      expect(currentLocation(), AppRoutes.settingsImportOpml);
    });

    testWidgets('does not redirect loop once already on import-opml', (
      tester,
    ) async {
      container.dispose();
      container = containerWithPendingShare();

      await pumpRouter(tester);
      expect(currentLocation(), AppRoutes.settingsImportOpml);

      // Re-running redirect logic (e.g. another notifyListeners) should not
      // bounce away from import-opml while a shared file is still pending.
      container.read(appRouterProvider).go(AppRoutes.settingsImportOpml);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(currentLocation(), AppRoutes.settingsImportOpml);
    });
  });
}
