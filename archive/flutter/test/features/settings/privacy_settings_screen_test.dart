import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/presentation/screens/privacy_settings_screen.dart';
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
        child: const MaterialApp(home: PrivacySettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'crash reporting and analytics toggles note they take effect on next '
    'launch',
    (tester) async {
      await pumpScreen(tester);

      expect(
        find.textContaining('Takes effect next time you restart Earshot.'),
        findsNWidgets(2),
      );
    },
  );

  testWidgets('crash reporting and analytics default to enabled', (
    tester,
  ) async {
    await pumpScreen(tester);

    final crashSwitch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Crash reports'),
    );
    final analyticsSwitch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Anonymous analytics'),
    );

    expect(crashSwitch.value, isTrue);
    expect(analyticsSwitch.value, isTrue);
  });
}
