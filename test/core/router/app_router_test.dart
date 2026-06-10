import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/core/router/app_router.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await AppSettingsRepositoryImpl(
      database: db,
    ).setOnboardingComplete(complete: true);
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
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
}
