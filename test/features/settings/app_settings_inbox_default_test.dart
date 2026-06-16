import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late AppSettingsRepositoryImpl repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = AppSettingsRepositoryImpl(database: db);
  });
  tearDown(() => db.close());

  test('defaults to null (No limit)', () async {
    expect(await repo.getInboxDefaultMaxEpisodes(), isNull);
  });

  test('round-trips a finite value', () async {
    await repo.setInboxDefaultMaxEpisodes(3);
    expect(await repo.getInboxDefaultMaxEpisodes(), 3);
  });

  test('setting back to null means No limit', () async {
    await repo.setInboxDefaultMaxEpisodes(3);
    await repo.setInboxDefaultMaxEpisodes(null);
    expect(await repo.getInboxDefaultMaxEpisodes(), isNull);
  });
}
