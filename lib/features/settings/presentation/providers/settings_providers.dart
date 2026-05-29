import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../data/app_settings_repository.dart';
import '../../data/quick_action_repository.dart';
import '../../data/quick_action_repository_impl.dart';
import '../../domain/quick_action_definition.dart';

final quickActionRepositoryProvider = Provider<QuickActionRepository>(
  (ref) => QuickActionRepositoryImpl(database: ref.watch(appDatabaseProvider)),
);

final episodeActionsProvider = FutureProvider<List<EpisodeAction>>(
  (ref) => ref.watch(quickActionRepositoryProvider).getEpisodeActions(),
);

final podcastActionsProvider = FutureProvider<List<PodcastAction>>(
  (ref) => ref.watch(quickActionRepositoryProvider).getPodcastActions(),
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
