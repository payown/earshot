import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:earshot/features/settings/presentation/screens/inbox_settings_screen.dart';
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
        child: const MaterialApp(home: InboxSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('default episodes row renders and shows No limit by default', (
    tester,
  ) async {
    await pumpScreen(tester);

    final row = tester.widget<ListTile>(
      find.widgetWithText(
        ListTile,
        'Default episodes per podcast in inbox',
      ),
    );
    final subtitle = row.subtitle! as Text;
    expect(subtitle.data, 'No limit');
  });

  testWidgets('reflects an existing stored value', (tester) async {
    await AppSettingsRepositoryImpl(database: db).setInboxDefaultMaxEpisodes(3);

    await pumpScreen(tester);

    final row = tester.widget<ListTile>(
      find.widgetWithText(
        ListTile,
        'Default episodes per podcast in inbox',
      ),
    );
    final subtitle = row.subtitle! as Text;
    expect(subtitle.data, '3');
  });

  testWidgets('selecting an option writes through to the repository', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(
      find.text('Default episodes per podcast in inbox'),
    );
    await tester.pumpAndSettle();

    // The picker sheet shows the options.
    expect(find.widgetWithText(RadioListTile<int?>, '5'), findsOneWidget);

    await tester.tap(find.widgetWithText(RadioListTile<int?>, '5'));
    await tester.pumpAndSettle();

    expect(
      await AppSettingsRepositoryImpl(
        database: db,
      ).getInboxDefaultMaxEpisodes(),
      5,
      reason: 'stored value should be 5',
    );
  });
}
