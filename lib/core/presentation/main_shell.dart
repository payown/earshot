import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/enums.dart';
import '../../features/downloads/presentation/providers/downloads_providers.dart';
import '../../features/downloads/presentation/screens/downloads_screen.dart';
import '../../features/downloads/presentation/screens/inbox_screen.dart';
import '../../features/player/presentation/screens/queue_screen.dart';
import '../../features/subscriptions/presentation/screens/subscriptions_screen.dart';
import '../providers/core_providers.dart';

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _currentIndex = 2; // Start on Subscriptions

  static const _tabs = [
    InboxScreen(),
    QueueScreen(),
    SubscriptionsScreen(),
    DownloadsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // Run queue expiration on app launch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(queueExpirationServiceProvider).runExpiration();
    });
  }

  @override
  Widget build(BuildContext context) {
    final inboxCount = ref.watch(_inboxCountProvider).asData?.value ?? 0;

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _tabs,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
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
            label: 'Subscriptions',
            tooltip: 'Subscriptions',
          ),
          const NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download),
            label: 'Downloads',
            tooltip: 'Downloads',
          ),
        ],
      ),
    );
  }
}

final _inboxCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.episodes)
        ..where((e) => e.status.equals(EpisodeStatus.newEpisode.name)))
      .watch()
      .map((rows) => rows.length);
});
