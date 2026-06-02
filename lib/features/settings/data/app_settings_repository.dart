import '../../../data/db/app_database.dart';

abstract interface class AppSettingsRepository {
  Future<int> getAutoDownloadCount();

  Future<void> setAutoDownloadCount(int count);

  // null = keep forever
  Future<int?> getHistoryRetentionDays();

  Future<void> setHistoryRetentionDays(int? days);

  Future<bool> isOnboardingComplete();

  Future<void> setOnboardingComplete({required bool complete});

  Future<bool> isCrashReportingEnabled();

  Future<void> setCrashReportingEnabled({required bool enabled});

  Future<bool> isAnalyticsEnabled();

  Future<void> setAnalyticsEnabled({required bool enabled});

  Future<bool> isSkipSilenceEnabled();

  Future<void> setSkipSilenceEnabled({required bool enabled});

  Future<bool> isVoiceEnhanceEnabled();

  Future<void> setVoiceEnhanceEnabled({required bool enabled});

  Future<bool> getDirectTouchEnabled();

  Future<void> setDirectTouchEnabled(bool value);

  Future<bool> isInboxOptInOnly();

  Future<void> setInboxOptInOnly({required bool value});

  Future<bool> isWifiOnlyDownloads();

  Future<void> setWifiOnlyDownloads({required bool value});

  Future<bool> isAutoDownloadInbox();

  Future<void> setAutoDownloadInbox({required bool value});

  Future<bool> isAutoDownloadQueue();

  Future<void> setAutoDownloadQueue({required bool value});

  // null = keep forever
  Future<int?> getDownloadRetentionDays();

  Future<void> setDownloadRetentionDays(int? days);
}

class AppSettingsRepositoryImpl implements AppSettingsRepository {
  const AppSettingsRepositoryImpl({required AppDatabase database})
    : _db = database;

  final AppDatabase _db;

  static const _keyAutoDownload = 'auto_download_count';
  static const _keyHistoryRetention = 'history_retention_days';
  static const _keyOnboardingComplete = 'onboarding_complete';
  static const _keyCrashReporting = 'crash_reporting_enabled';
  static const _keyAnalytics = 'analytics_enabled';
  static const _keySkipSilence = 'skip_silence_enabled';
  static const _keyVoiceEnhance = 'voice_enhance_enabled';
  static const _keyDirectTouch = 'direct_touch_enabled';
  static const _keyInboxOptInOnly = 'inbox_opt_in_only';
  static const _keyWifiOnlyDownloads = 'wifi_only_downloads';
  static const _keyAutoDownloadInbox = 'auto_download_inbox';
  static const _keyAutoDownloadQueue = 'auto_download_queue';
  static const _keyDownloadRetentionDays = 'download_retention_days';
  static const _keyLastPlayingEpisodeId = 'last_playing_episode_id';
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

  @override
  Future<bool> isOnboardingComplete() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keyOnboardingComplete))).getSingleOrNull();
    return row?.value == 'true';
  }

  @override
  Future<void> setOnboardingComplete({required bool complete}) =>
      _set(_keyOnboardingComplete, complete.toString());

  @override
  Future<bool> isCrashReportingEnabled() =>
      _getBool(_keyCrashReporting, defaultValue: true);

  @override
  Future<void> setCrashReportingEnabled({required bool enabled}) =>
      _set(_keyCrashReporting, enabled.toString());

  @override
  Future<bool> isAnalyticsEnabled() =>
      _getBool(_keyAnalytics, defaultValue: true);

  @override
  Future<void> setAnalyticsEnabled({required bool enabled}) =>
      _set(_keyAnalytics, enabled.toString());

  @override
  Future<bool> isSkipSilenceEnabled() =>
      _getBool(_keySkipSilence, defaultValue: false);

  @override
  Future<void> setSkipSilenceEnabled({required bool enabled}) =>
      _set(_keySkipSilence, enabled.toString());

  @override
  Future<bool> isVoiceEnhanceEnabled() =>
      _getBool(_keyVoiceEnhance, defaultValue: false);

  @override
  Future<void> setVoiceEnhanceEnabled({required bool enabled}) =>
      _set(_keyVoiceEnhance, enabled.toString());

  @override
  Future<bool> getDirectTouchEnabled() =>
      _getBool(_keyDirectTouch, defaultValue: false);

  @override
  Future<void> setDirectTouchEnabled(bool value) =>
      _set(_keyDirectTouch, value.toString());

  @override
  Future<bool> isInboxOptInOnly() =>
      _getBool(_keyInboxOptInOnly, defaultValue: false);

  @override
  Future<void> setInboxOptInOnly({required bool value}) =>
      _set(_keyInboxOptInOnly, value.toString());

  @override
  Future<bool> isWifiOnlyDownloads() =>
      _getBool(_keyWifiOnlyDownloads, defaultValue: true);

  @override
  Future<void> setWifiOnlyDownloads({required bool value}) =>
      _set(_keyWifiOnlyDownloads, value.toString());

  @override
  Future<bool> isAutoDownloadInbox() =>
      _getBool(_keyAutoDownloadInbox, defaultValue: false);

  @override
  Future<void> setAutoDownloadInbox({required bool value}) =>
      _set(_keyAutoDownloadInbox, value.toString());

  @override
  Future<bool> isAutoDownloadQueue() =>
      _getBool(_keyAutoDownloadQueue, defaultValue: false);

  @override
  Future<void> setAutoDownloadQueue({required bool value}) =>
      _set(_keyAutoDownloadQueue, value.toString());

  @override
  Future<int?> getDownloadRetentionDays() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keyDownloadRetentionDays))).getSingleOrNull();
    if (row == null) return null;
    if (row.value == 'null') return null;
    return int.tryParse(row.value);
  }

  @override
  Future<void> setDownloadRetentionDays(int? days) =>
      _set(_keyDownloadRetentionDays, days?.toString() ?? 'null');

  Future<int?> getLastPlayingEpisodeId() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keyLastPlayingEpisodeId))).getSingleOrNull();
    return row == null ? null : int.tryParse(row.value);
  }

  Future<void> setLastPlayingEpisodeId(int? id) async {
    if (id == null) {
      await (_db.delete(
        _db.appSettings,
      )..where((s) => s.key.equals(_keyLastPlayingEpisodeId))).go();
    } else {
      await _set(_keyLastPlayingEpisodeId, id.toString());
    }
  }

  Future<bool> _getBool(String key, {required bool defaultValue}) async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    if (row == null) return defaultValue;
    return row.value == 'true';
  }

  Future<void> _set(String key, String value) async {
    await _db
        .into(_db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: key, value: value),
        );
  }
}
