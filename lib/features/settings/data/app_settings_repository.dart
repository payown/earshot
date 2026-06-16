import '../../../data/db/app_database.dart';

enum LaunchScreen { inbox, queue, library, downloads }

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

  Future<bool> isGroupQueueEpisodes();

  Future<void> setGroupQueueEpisodes({required bool enabled});

  Future<bool> isContinueAfterQueue();

  Future<void> setContinueAfterQueue({required bool value});

  Future<bool> isContinueAfterGroupEnds();

  Future<void> setContinueAfterGroupEnds({required bool value});

  Future<bool> isPodcastNameFirst();

  Future<void> setPodcastNameFirst({required bool value});

  Future<bool> isClearFromInboxAlsoMarksPlayed();

  Future<void> setClearFromInboxAlsoMarksPlayed({required bool value});

  Future<bool> hasSeenPodcastNameTip();

  Future<void> setHasSeenPodcastNameTip({required bool value});

  Future<bool> isGaplessPlaybackEnabled();

  Future<void> setGaplessPlaybackEnabled({required bool value});

  Future<bool> hasSeenGaplessTip();

  Future<void> setHasSeenGaplessTip({required bool value});

  // null = keep forever
  Future<int?> getDownloadRetentionDays();

  Future<void> setDownloadRetentionDays(int? days);

  // null = No limit (default). Number = keep at most N newest episodes per
  // podcast in the inbox, unless the podcast overrides it.
  Future<int?> getInboxDefaultMaxEpisodes();

  Future<void> setInboxDefaultMaxEpisodes(int? max);

  Future<bool> isDownloadAuditEnabled();

  Future<void> setDownloadAuditEnabled({required bool value});

  // null = no cap
  Future<int?> getStorageCapBytes();

  Future<void> setStorageCapBytes(int? bytes);

  Future<double> getGlobalSpeed();

  Future<void> setGlobalSpeed(double speed);

  Future<int> getSkipForwardSeconds();

  Future<void> setSkipForwardSeconds(int seconds);

  Future<int> getSkipBackSeconds();

  Future<void> setSkipBackSeconds(int seconds);

  Future<DateTime?> getLastAutoRefreshAt();

  Future<void> setLastAutoRefreshAt(DateTime value);

  Future<LaunchScreen> getDefaultLaunchScreen();

  Future<void> setDefaultLaunchScreen(LaunchScreen screen);
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
  static const _keyGroupQueueEpisodes = 'group_queue_episodes';
  static const _keyContinueAfterQueue = 'continue_after_queue';
  static const _keyContinueAfterGroup = 'continue_after_group';
  static const _keyPodcastNameFirst = 'podcast_name_first';
  static const _keyClearFromInboxMarksPlayed = 'clear_from_inbox_marks_played';
  static const _keyPodcastNameTipSeen = 'podcast_name_tip_seen';
  static const _keyGaplessPlayback = 'gapless_playback_enabled';
  static const _keyGaplessTipSeen = 'gapless_tip_seen';
  static const _keyDownloadRetentionDays = 'download_retention_days';
  static const _keyInboxDefaultMaxEpisodes = 'inbox_default_max_episodes';
  static const _keyDownloadAudit = 'download_audit_announcements';
  static const _keyStorageCapBytes = 'storage_cap_bytes';
  static const _keyLastPlayingEpisodeId = 'last_playing_episode_id';
  static const _keyGlobalSpeed = 'global_speed';
  static const _keySkipForwardSeconds = 'skip_forward_seconds';
  static const _keySkipBackSeconds = 'skip_back_seconds';
  static const _keyLastAutoRefreshAt = 'last_auto_refresh_at';
  static const _keyDefaultLaunchScreen = 'default_launch_screen';
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
  Future<bool> isGroupQueueEpisodes() =>
      _getBool(_keyGroupQueueEpisodes, defaultValue: false);

  @override
  Future<void> setGroupQueueEpisodes({required bool enabled}) =>
      _set(_keyGroupQueueEpisodes, enabled.toString());

  @override
  Future<bool> isContinueAfterQueue() =>
      _getBool(_keyContinueAfterQueue, defaultValue: false);

  @override
  Future<void> setContinueAfterQueue({required bool value}) =>
      _set(_keyContinueAfterQueue, value.toString());

  @override
  Future<bool> isContinueAfterGroupEnds() =>
      _getBool(_keyContinueAfterGroup, defaultValue: true);

  @override
  Future<void> setContinueAfterGroupEnds({required bool value}) =>
      _set(_keyContinueAfterGroup, value.toString());

  @override
  Future<bool> isPodcastNameFirst() =>
      _getBool(_keyPodcastNameFirst, defaultValue: false);

  @override
  Future<void> setPodcastNameFirst({required bool value}) =>
      _set(_keyPodcastNameFirst, value.toString());

  @override
  Future<bool> isClearFromInboxAlsoMarksPlayed() =>
      _getBool(_keyClearFromInboxMarksPlayed, defaultValue: false);

  @override
  Future<void> setClearFromInboxAlsoMarksPlayed({required bool value}) =>
      _set(_keyClearFromInboxMarksPlayed, value.toString());

  @override
  Future<bool> hasSeenPodcastNameTip() =>
      _getBool(_keyPodcastNameTipSeen, defaultValue: false);

  @override
  Future<void> setHasSeenPodcastNameTip({required bool value}) =>
      _set(_keyPodcastNameTipSeen, value.toString());

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

  @override
  Future<int?> getInboxDefaultMaxEpisodes() async {
    final row =
        await (_db.select(_db.appSettings)
              ..where((s) => s.key.equals(_keyInboxDefaultMaxEpisodes)))
            .getSingleOrNull();
    if (row == null || row.value == 'null') return null;
    return int.tryParse(row.value);
  }

  @override
  Future<void> setInboxDefaultMaxEpisodes(int? max) =>
      _set(_keyInboxDefaultMaxEpisodes, max?.toString() ?? 'null');

  @override
  Future<bool> isGaplessPlaybackEnabled() =>
      _getBool(_keyGaplessPlayback, defaultValue: true);

  @override
  Future<void> setGaplessPlaybackEnabled({required bool value}) =>
      _set(_keyGaplessPlayback, value.toString());

  @override
  Future<bool> hasSeenGaplessTip() =>
      _getBool(_keyGaplessTipSeen, defaultValue: false);

  @override
  Future<void> setHasSeenGaplessTip({required bool value}) =>
      _set(_keyGaplessTipSeen, value.toString());

  @override
  Future<bool> isDownloadAuditEnabled() =>
      _getBool(_keyDownloadAudit, defaultValue: false);

  @override
  Future<void> setDownloadAuditEnabled({required bool value}) =>
      _set(_keyDownloadAudit, value.toString());

  @override
  Future<int?> getStorageCapBytes() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keyStorageCapBytes))).getSingleOrNull();
    if (row == null) return null;
    if (row.value == 'null') return null;
    return int.tryParse(row.value);
  }

  @override
  Future<void> setStorageCapBytes(int? bytes) =>
      _set(_keyStorageCapBytes, bytes?.toString() ?? 'null');

  @override
  Future<double> getGlobalSpeed() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keyGlobalSpeed))).getSingleOrNull();
    if (row == null) return 1.0;
    return double.tryParse(row.value) ?? 1.0;
  }

  @override
  Future<void> setGlobalSpeed(double speed) =>
      _set(_keyGlobalSpeed, speed.toString());

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

  static const _validSkipSeconds = [10, 15, 30, 45, 60, 90];

  static int _clampSkipSeconds(int? value, int defaultValue) {
    if (value == null || !_validSkipSeconds.contains(value))
      return defaultValue;
    return value;
  }

  @override
  Future<int> getSkipForwardSeconds() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keySkipForwardSeconds))).getSingleOrNull();
    return _clampSkipSeconds(int.tryParse(row?.value ?? ''), 30);
  }

  @override
  Future<void> setSkipForwardSeconds(int seconds) =>
      _set(_keySkipForwardSeconds, _clampSkipSeconds(seconds, 30).toString());

  @override
  Future<int> getSkipBackSeconds() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keySkipBackSeconds))).getSingleOrNull();
    return _clampSkipSeconds(int.tryParse(row?.value ?? ''), 15);
  }

  @override
  Future<void> setSkipBackSeconds(int seconds) =>
      _set(_keySkipBackSeconds, _clampSkipSeconds(seconds, 15).toString());

  @override
  Future<DateTime?> getLastAutoRefreshAt() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keyLastAutoRefreshAt))).getSingleOrNull();
    if (row == null) return null;
    return DateTime.tryParse(row.value);
  }

  @override
  Future<void> setLastAutoRefreshAt(DateTime value) =>
      _set(_keyLastAutoRefreshAt, value.toUtc().toIso8601String());

  @override
  Future<LaunchScreen> getDefaultLaunchScreen() async {
    final row = await (_db.select(
      _db.appSettings,
    )..where((s) => s.key.equals(_keyDefaultLaunchScreen))).getSingleOrNull();
    if (row == null) return LaunchScreen.library;
    return LaunchScreen.values.asNameMap()[row.value] ?? LaunchScreen.library;
  }

  @override
  Future<void> setDefaultLaunchScreen(LaunchScreen screen) =>
      _set(_keyDefaultLaunchScreen, screen.name);

  Future<void> _set(String key, String value) async {
    await _db
        .into(_db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: key, value: value),
        );
  }
}
