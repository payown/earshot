import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../data/stats_repository.dart';
import '../../domain/stats_period.dart';

final statsRepositoryProvider = Provider<StatsRepository>(
  (ref) => StatsRepositoryImpl(database: ref.watch(appDatabaseProvider)),
);

final statsProvider = FutureProvider.family<ListeningStats, StatsPeriod>((
  ref,
  period,
) {
  return ref.watch(statsRepositoryProvider).getStats(period);
});
