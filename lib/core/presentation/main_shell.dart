import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shake/shake.dart';

import '../../data/db/enums.dart';
import '../../features/downloads/presentation/providers/downloads_providers.dart';
import '../../features/player/presentation/widgets/now_playing_bar.dart';
import '../../features/settings/data/app_settings_repository.dart';
import '../../features/stats/data/stats_repository.dart';
import '../providers/core_providers.dart';
import '../router/app_router.dart';

class MainShell extends ConsumerStatefulWidget {
  const MainShell({required this.shell, super.key});

  final StatefulNavigationShell shell;

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  ShakeDetector? _shakeDetector;
  DateTime? _lastShake;

  void _onShake() {
    final now = DateTime.now();
    if (_lastShake != null &&
        now.difference(_lastShake!) < const Duration(seconds: 3)) {
      return;
    }
    _lastShake = now;
    if (mounted) context.push(AppRoutes.bugReport);
  }

  Future<void> _applyHistoryRetention() async {
    final db = ref.read(appDatabaseProvider);
    final days = await AppSettingsRepositoryImpl(
      database: db,
    ).getHistoryRetentionDays();
    await StatsRepositoryImpl(database: db).applyRetentionPolicy(days);
  }

  @override
  void initState() {
    super.initState();
    // Shake package defaults (single jerk, 2.7g threshold) fire on casual
    // movement like pocketing the phone. Require three distinct jerks within
    // one second, each at least 100 ms apart, and at 4.0g — a deliberate
    // shake gesture, not an accidental bump.
    _shakeDetector = ShakeDetector.autoStart(
      onPhoneShake: _onShake,
      minimumShakeCount: 3,
      shakeSlopTimeMS: 100,
      shakeCountResetTime: 1000,
      shakeThresholdGravity: 4.5,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      ref.read(queueExpirationServiceProvider).runExpiration();
      await _applyHistoryRetention();
    });
  }

  @override
  void dispose() {
    _shakeDetector?.stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inboxCount = ref.watch(_inboxCountProvider).asData?.value ?? 0;

    return Scaffold(
      body: widget.shell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const NowPlayingBar(),
          NavigationBar(
            selectedIndex: widget.shell.currentIndex,
            onDestinationSelected: (index) => widget.shell.goBranch(
              index,
              initialLocation: index == widget.shell.currentIndex,
            ),
            destinations: [
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: inboxCount > 0,
                  label: Text('$inboxCount'),
                  child: const Icon(Icons.inbox_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: inboxCount > 0,
                  label: Text('$inboxCount'),
                  child: const Icon(Icons.inbox),
                ),
                label: 'Inbox',
                tooltip: inboxCount > 0 ? 'Inbox, $inboxCount new' : 'Inbox',
              ),
              const NavigationDestination(
                icon: Icon(Icons.queue_music_outlined),
                selectedIcon: Icon(Icons.queue_music),
                label: 'Queue',
                tooltip: 'Queue',
              ),
              const NavigationDestination(
                icon: Icon(Icons.podcasts_outlined),
                selectedIcon: Icon(Icons.podcasts),
                label: 'Library',
                tooltip: 'Library',
              ),
              const NavigationDestination(
                icon: Icon(Icons.download_outlined),
                selectedIcon: Icon(Icons.download),
                label: 'Downloads',
                tooltip: 'Downloads',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

final _inboxCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.episodes)..where(
        (e) =>
            e.status.equals(EpisodeStatus.newEpisode.name) &
            e.inboxDismissed.equals(false),
      ))
      .watch()
      .map((rows) => rows.length);
});
