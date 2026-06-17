import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../data/db/app_database.dart';
import '../../../../features/settings/data/app_settings_repository.dart';
import '../../data/download_manager.dart';
import '../../data/inbox_limit_service.dart';
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

final downloadAuditEventsProvider = StreamProvider<String>(
  (ref) => ref.watch(downloadManagerProvider).downloadAuditEvents,
);

final downloadOutcomesProvider = StreamProvider<DownloadOutcome>(
  (ref) => ref.watch(downloadManagerProvider).downloadOutcomes,
);

final queueExpirationServiceProvider = Provider<QueueExpirationService>(
  (ref) => QueueExpirationService(database: ref.watch(appDatabaseProvider)),
);

final inboxLimitServiceProvider = Provider<InboxLimitService>(
  (ref) => InboxLimitService(
    database: ref.watch(appDatabaseProvider),
    settings: AppSettingsRepositoryImpl(
      database: ref.watch(appDatabaseProvider),
    ),
  ),
);

final recentlyExpiredProvider = StreamProvider<List<RecentlyExpiredRow>>(
  (ref) => ref.watch(queueExpirationServiceProvider).watchRecentlyExpired(),
);

final totalDownloadBytesProvider = FutureProvider<int>(
  (ref) => ref.watch(downloadManagerProvider).getTotalDownloadBytes(),
);
