import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../data/db/app_database.dart';
import '../../../../features/settings/data/app_settings_repository.dart';
import '../../data/download_manager.dart';
import '../../data/queue_expiration_service.dart';

final downloadManagerProvider = Provider<DownloadManager>(
  (ref) {
    final db = ref.watch(appDatabaseProvider);
    return DownloadManager(
      database: db,
      settings: AppSettingsRepositoryImpl(database: db),
    );
  },
);

final queueExpirationServiceProvider = Provider<QueueExpirationService>(
  (ref) => QueueExpirationService(database: ref.watch(appDatabaseProvider)),
);

final recentlyExpiredProvider = StreamProvider<List<RecentlyExpiredRow>>(
  (ref) => ref.watch(queueExpirationServiceProvider).watchRecentlyExpired(),
);
