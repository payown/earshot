import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../data/app_settings_repository.dart';
import '../../data/quick_action_repository.dart';
import '../../data/quick_action_repository_impl.dart';
import '../../domain/quick_action_definition.dart';

final quickActionRepositoryProvider = Provider<QuickActionRepository>(
  (ref) => QuickActionRepositoryImpl(database: ref.watch(appDatabaseProvider)),
);

final episodeActionsProvider = StreamProvider<List<EpisodeAction>>(
  (ref) => ref.watch(quickActionRepositoryProvider).watchEpisodeActions(),
);

final podcastActionsProvider = StreamProvider<List<PodcastAction>>(
  (ref) => ref.watch(quickActionRepositoryProvider).watchPodcastActions(),
);

class _BoolSettingNotifier extends AsyncNotifier<bool> {
  _BoolSettingNotifier({
    required Future<bool> Function(AppSettingsRepositoryImpl) read,
    required Future<void> Function(AppSettingsRepositoryImpl, bool) write,
  }) : _read = read,
       _write = write;

  final Future<bool> Function(AppSettingsRepositoryImpl) _read;
  final Future<void> Function(AppSettingsRepositoryImpl, bool) _write;

  @override
  Future<bool> build() async {
    final db = ref.watch(appDatabaseProvider);
    return _read(AppSettingsRepositoryImpl(database: db));
  }

  Future<void> set(bool value) async {
    state = AsyncData(value);
    final db = ref.read(appDatabaseProvider);
    await _write(AppSettingsRepositoryImpl(database: db), value);
  }
}

final inboxOptInOnlyProvider =
    AsyncNotifierProvider<_BoolSettingNotifier, bool>(
      () => _BoolSettingNotifier(
        read: (r) => r.isInboxOptInOnly(),
        write: (r, v) => r.setInboxOptInOnly(value: v),
      ),
    );

final wifiOnlyDownloadsProvider =
    AsyncNotifierProvider<_BoolSettingNotifier, bool>(
      () => _BoolSettingNotifier(
        read: (r) => r.isWifiOnlyDownloads(),
        write: (r, v) => r.setWifiOnlyDownloads(value: v),
      ),
    );

final autoDownloadInboxProvider =
    AsyncNotifierProvider<_BoolSettingNotifier, bool>(
      () => _BoolSettingNotifier(
        read: (r) => r.isAutoDownloadInbox(),
        write: (r, v) => r.setAutoDownloadInbox(value: v),
      ),
    );

final autoDownloadQueueProvider =
    AsyncNotifierProvider<_BoolSettingNotifier, bool>(
      () => _BoolSettingNotifier(
        read: (r) => r.isAutoDownloadQueue(),
        write: (r, v) => r.setAutoDownloadQueue(value: v),
      ),
    );

final groupQueueEpisodesProvider =
    AsyncNotifierProvider<_BoolSettingNotifier, bool>(
      () => _BoolSettingNotifier(
        read: (r) => r.isGroupQueueEpisodes(),
        write: (r, v) => r.setGroupQueueEpisodes(enabled: v),
      ),
    );

final continueAfterQueueProvider =
    AsyncNotifierProvider<_BoolSettingNotifier, bool>(
      () => _BoolSettingNotifier(
        read: (r) => r.isContinueAfterQueue(),
        write: (r, v) => r.setContinueAfterQueue(value: v),
      ),
    );

class _RetentionSettingNotifier extends AsyncNotifier<int?> {
  @override
  Future<int?> build() async {
    final db = ref.watch(appDatabaseProvider);
    return AppSettingsRepositoryImpl(database: db).getDownloadRetentionDays();
  }

  Future<void> set(int? days) async {
    state = AsyncData(days);
    final db = ref.read(appDatabaseProvider);
    await AppSettingsRepositoryImpl(
      database: db,
    ).setDownloadRetentionDays(days);
  }
}

final downloadRetentionDaysProvider =
    AsyncNotifierProvider<_RetentionSettingNotifier, int?>(
      _RetentionSettingNotifier.new,
    );
