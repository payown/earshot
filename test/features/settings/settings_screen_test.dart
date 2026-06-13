import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/core/router/app_router.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/presentation/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const SettingsScreen()),
        GoRoute(
          path: AppRoutes.tutorial,
          builder: (_, __) => const Scaffold(body: Text('Tutorial Screen')),
        ),
        GoRoute(
          path: AppRoutes.settingsGeneral,
          builder: (_, __) => const Scaffold(body: Text('General Screen')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows a View Tutorial entry', (tester) async {
    await pumpScreen(tester);

    await tester.scrollUntilVisible(
      find.text('View Tutorial'),
      200,
      scrollable: find.byType(Scrollable),
    );

    expect(find.text('View Tutorial'), findsOneWidget);
  });

  testWidgets('tapping View Tutorial navigates to the tutorial route', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.scrollUntilVisible(
      find.text('View Tutorial'),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.tap(find.text('View Tutorial'));
    await tester.pumpAndSettle();

    expect(find.text('Tutorial Screen'), findsOneWidget);
  });

  testWidgets('shows a General entry', (tester) async {
    await pumpScreen(tester);

    expect(find.text('General'), findsOneWidget);
  });

  testWidgets('tapping General navigates to the general settings route', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.text('General'));
    await tester.pumpAndSettle();

    expect(find.text('General Screen'), findsOneWidget);
  });
}
