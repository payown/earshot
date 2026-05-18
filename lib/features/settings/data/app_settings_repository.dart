import '../../../data/db/app_database.dart';

abstract interface class AppSettingsRepository {
  Future<int> getAutoDownloadCount();

  Future<void> setAutoDownloadCount(int count);
}

class AppSettingsRepositoryImpl implements AppSettingsRepository {
  const AppSettingsRepositoryImpl({required AppDatabase database})
    : _db = database;

  final AppDatabase _db;

  static const _keyAutoDownload = 'auto_download_count';
  static const _defaultAutoDownload = 3;

  @override
  Future<int> getAutoDownloadCount() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keyAutoDownload))).getSingleOrNull();
    if (row == null) return _defaultAutoDownload;
    return int.tryParse(row.value) ?? _defaultAutoDownload;
  }

  @override
  Future<void> setAutoDownloadCount(int count) async {
    await _db
        .into(_db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: _keyAutoDownload,
            value: count.toString(),
          ),
        );
  }
}
