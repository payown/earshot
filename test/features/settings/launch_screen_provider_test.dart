import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:earshot/features/settings/presentation/providers/settings_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('set() reverts state and rethrows when persistence fails', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    expect(
      await container.read(defaultLaunchScreenProvider.future),
      LaunchScreen.library,
    );

    await db.close();

    await expectLater(
      container
          .read(defaultLaunchScreenProvider.notifier)
          .set(
            LaunchScreen.inbox,
          ),
      throwsA(anything),
    );

    expect(
      container.read(defaultLaunchScreenProvider).value,
      LaunchScreen.library,
    );
  });
}
