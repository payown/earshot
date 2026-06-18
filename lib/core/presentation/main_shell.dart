import 'dart:async';

import 'package:drift/drift.dart' hide Column, View;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:shake/shake.dart';

import '../../data/db/enums.dart';
import '../../features/downloads/presentation/providers/downloads_providers.dart';
import '../../features/player/presentation/widgets/now_playing_bar.dart';
import '../../features/settings/data/app_settings_repository.dart';
import '../../features/stats/data/stats_repository.dart';
import '../providers/core_providers.dart';
import '../router/app_router.dart';
import 'widgets/accessible_nav_bar.dart';

final _log = Logger('MainShell');

class MainShell extends ConsumerStatefulWidget {
  const MainShell({required this.shell, super.key});

  final StatefulNavigationShell shell;

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  ShakeDetector? _shakeDetector;
  DateTime? _lastShake;

  void _onShake(ShakeEvent _) {
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
    // one second, each at least 100 ms apart, and at 4.5g — a deliberate
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
      // Apply inbox count caps and age limits. Early-outs cheaply when no limits
      // are set, so the common no-limits case adds effectively no launch work.
      unawaited(ref.read(inboxLimitServiceProvider).applyInboxLimits());
      // Run history retention independently so a slow DB operation doesn't
      // push the VoiceOver focus nudge past the window where it's effective.
      unawaited(
        _applyHistoryRetention().catchError((Object e, StackTrace st) {
          _log.warning('History retention failed', e, st);
        }),
      );
      // After the shell's first frame, nudge VoiceOver focus into app content.
      // The GoRouter redirect from /loading -> initial tab resolves before
      // Flutter posts its screen-changed notification, which leaves VoiceOver
      // focus stranded on the iOS status bar. A zero-length announcement causes
      // VoiceOver to re-evaluate focus and land on the first in-app element.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (mounted) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          '',
          TextDirection.ltr,
        );
      }
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
          AccessibleNavBar(
            selectedIndex: widget.shell.currentIndex,
            onDestinationSelected: (index) => widget.shell.goBranch(
              index,
              initialLocation: index == widget.shell.currentIndex,
            ),
            destinations: [
              AccessibleNavDestination(
                icon: Icons.inbox_outlined,
                selectedIcon: Icons.inbox,
                label: 'Inbox',
                semanticLabel: inboxCount > 0
                    ? 'Inbox, $inboxCount new'
                    : 'Inbox',
                badgeCount: inboxCount,
              ),
              const AccessibleNavDestination(
                icon: Icons.queue_music_outlined,
                selectedIcon: Icons.queue_music,
                label: 'Queue',
              ),
              const AccessibleNavDestination(
                icon: Icons.podcasts_outlined,
                selectedIcon: Icons.podcasts,
                label: 'Library',
              ),
              const AccessibleNavDestination(
                icon: Icons.download_outlined,
                selectedIcon: Icons.download,
                label: 'Downloads',
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
  // Count in SQL rather than fetching every matching row and reading .length.
  // This provider is alive app-wide (the bottom-nav badge) and re-fires on every
  // episode change during a refresh, so fetching full rows just to count was a
  // hot path on large libraries (#278). Backed by idx_episodes_inbox.
  final count = db.episodes.id.count();
  final query = db.selectOnly(db.episodes)
    ..addColumns([count])
    ..where(
      db.episodes.status.equals(EpisodeStatus.newEpisode.name) &
          db.episodes.inboxDismissed.equals(false),
    );
  return query.map((row) => row.read(count) ?? 0).watchSingle();
});
