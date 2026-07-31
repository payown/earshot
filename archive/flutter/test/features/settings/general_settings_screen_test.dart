import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:earshot/features/settings/presentation/screens/general_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: GeneralSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('defaults to Library', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Default launch screen'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
  });

  testWidgets('picker lists all four launch screen options', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Default launch screen'));
    await tester.pumpAndSettle();

    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Library'), findsWidgets);
    expect(find.text('Downloads'), findsOneWidget);
  });

  testWidgets('choosing Inbox updates the subtitle and persists', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Default launch screen'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();

    expect(find.text('Inbox'), findsOneWidget);

    final stored = await AppSettingsRepositoryImpl(
      database: db,
    ).getDefaultLaunchScreen();
    expect(stored, LaunchScreen.inbox);
  });
}
