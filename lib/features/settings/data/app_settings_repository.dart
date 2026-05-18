import '../../../data/db/app_database.dart';

abstract interface class AppSettingsRepository {
  Future<int> getAutoDownloadCount();

  Future<void> setAutoDownloadCount(int count);

  // null = keep forever
  Future<int?> getHistoryRetentionDays();

  Future<void> setHistoryRetentionDays(int? days);
}

class AppSettingsRepositoryImpl implements AppSettingsRepository {
  const AppSettingsRepositoryImpl({required AppDatabase database})
    : _db = database;

  final AppDatabase _db;

  static const _keyAutoDownload = 'auto_download_count';
  static const _keyHistoryRetention = 'history_retention_days';
  static const _defaultAutoDownload = 3;
  static const _defaultHistoryRetention = 90;

  @override
  Future<int> getAutoDownloadCount() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keyAutoDownload))).getSingleOrNull();
    if (row == null) return _defaultAutoDownload;
    return int.tryParse(row.value) ?? _defaultAutoDownload;
  }

  @override
  Future<void> setAutoDownloadCount(int count) => _set(
    _keyAutoDownload,
    count.toString(),
  );

  @override
  Future<int?> getHistoryRetentionDays() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keyHistoryRetention))).getSingleOrNull();
    if (row == null) return _defaultHistoryRetention;
    if (row.value == 'null') return null;
    return int.tryParse(row.value) ?? _defaultHistoryRetention;
  }

  @override
  Future<void> setHistoryRetentionDays(int? days) => _set(
    _keyHistoryRetention,
    days?.toString() ?? 'null',
  );

  Future<void> _set(String key, String value) async {
    await _db
        .into(_db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: key, value: value),
        );
  }
}
