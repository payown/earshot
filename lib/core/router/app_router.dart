import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db/enums.dart';
import '../../features/downloads/presentation/screens/downloads_screen.dart';
import '../../features/downloads/presentation/screens/inbox_screen.dart';
import '../../features/onboarding/presentation/screens/onboarding_screen.dart';
import '../../features/player/presentation/screens/player_screen.dart';
import '../../features/player/presentation/screens/queue_screen.dart';
import '../../features/search/presentation/screens/opml_import_screen.dart';
import '../../features/search/presentation/screens/search_screen.dart';
import '../../features/settings/data/app_settings_repository.dart';
import '../../features/settings/presentation/screens/privacy_settings_screen.dart';
import '../../features/settings/presentation/screens/quick_action_configurator_screen.dart';
import '../../features/settings/presentation/screens/settings_screen.dart';
import '../../features/stats/presentation/screens/stats_screen.dart';
import '../../features/folders/presentation/screens/folder_detail_screen.dart';
import '../../features/subscriptions/presentation/screens/add_podcast_screen.dart';
import '../../features/subscriptions/presentation/screens/podcast_detail_screen.dart';
import '../../features/subscriptions/presentation/screens/subscriptions_screen.dart';
import '../presentation/main_shell.dart';
import '../providers/core_providers.dart';

// Route path constants — single source of truth for all navigation.
abstract final class AppRoutes {
  static const loading = '/loading';
  static const onboarding = '/onboarding';
  static const inbox = '/inbox';
  static const queue = '/queue';
  static const subscriptions = '/subscriptions';
  static String podcastDetail(int id) => '/subscriptions/$id';
  static String folderDetail(int id) => '/subscriptions/folders/$id';
  static const downloads = '/downloads';
  static const search = '/search';
  static const addPodcast = '/add-podcast';
  static const player = '/player';
  static const settings = '/settings';
  static const settingsImportOpml = '/settings/import-opml';
  static const settingsStats = '/settings/stats';
  static const settingsPrivacy = '/settings/privacy';
  static String settingsQuickActions(String type) =>
      '/settings/quick-actions/$type';
}

// ── Onboarding state ─────────────────────────────────────────────────────────

final isOnboardingCompleteProvider = FutureProvider<bool>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  return AppSettingsRepositoryImpl(database: db).isOnboardingComplete();
});

// ── Router notifier (ChangeNotifier for GoRouter.refreshListenable) ───────────

class _RouterNotifier extends ChangeNotifier {
  _RouterNotifier(this._ref) {
    _ref.listen(isOnboardingCompleteProvider, (_, __) => notifyListeners());
  }

  final Ref _ref;

  String? redirect(BuildContext context, GoRouterState state) {
    final atLoading = state.matchedLocation == AppRoutes.loading;
    final async = _ref.read(isOnboardingCompleteProvider);
    return async.when(
      // Stay on the loading screen while the DB check is in flight.
      loading: () => atLoading ? null : AppRoutes.loading,
      error: (_, __) => AppRoutes.subscriptions,
      data: (done) {
        if (atLoading) {
          return done ? AppRoutes.subscriptions : AppRoutes.onboarding;
        }
        final atOnboarding = state.matchedLocation.startsWith(
          AppRoutes.onboarding,
        );
        if (!done && !atOnboarding) return AppRoutes.onboarding;
        if (done && atOnboarding) return AppRoutes.subscriptions;
        return null;
      },
    );
  }
}

final _routerNotifierProvider = Provider<_RouterNotifier>(
  (ref) => _RouterNotifier(ref),
);

// ── Navigator keys ────────────────────────────────────────────────────────────

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

// ── App router ────────────────────────────────────────────────────────────────

final appRouterProvider = Provider<GoRouter>((ref) {
  final notifier = ref.watch(_routerNotifierProvider);

  final router = GoRouter(
    navigatorKey: _rootKey,
    initialLocation: AppRoutes.loading,
    refreshListenable: notifier,
    redirect: notifier.redirect,
    routes: [
      // ── Loading screen (shown while onboarding state is resolving) ────────
      GoRoute(
        path: AppRoutes.loading,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      ),

      // ── Full-screen routes (above shell, no bottom nav) ──────────────────
      GoRoute(
        path: AppRoutes.onboarding,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const OnboardingScreen(),
      ),
      GoRoute(
        path: AppRoutes.search,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const SearchScreen(),
      ),
      GoRoute(
        path: AppRoutes.addPodcast,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const AddPodcastScreen(),
      ),
      GoRoute(
        path: AppRoutes.player,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const PlayerScreen(),
      ),
      GoRoute(
        path: AppRoutes.settings,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const SettingsScreen(),
        routes: [
          GoRoute(
            path: 'import-opml',
            parentNavigatorKey: _rootKey,
            builder: (_, __) => const OpmlImportScreen(),
          ),
          GoRoute(
            path: 'stats',
            parentNavigatorKey: _rootKey,
            builder: (_, __) => const StatsScreen(),
          ),
          GoRoute(
            path: 'privacy',
            parentNavigatorKey: _rootKey,
            builder: (_, __) => const PrivacySettingsScreen(),
          ),
          GoRoute(
            path: 'quick-actions/:type',
            parentNavigatorKey: _rootKey,
            builder: (_, state) {
              final type = state.pathParameters['type']!;
              final contentType = QuickActionContentType.values.byName(type);
              return QuickActionConfiguratorScreen(contentType: contentType);
            },
          ),
        ],
      ),

      // ── Shell with bottom navigation ─────────────────────────────────────
      StatefulShellRoute.indexedStack(
        builder: (_, __, shell) => MainShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.inbox,
                builder: (_, __) => const InboxScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.queue,
                builder: (_, __) => const QueueScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.subscriptions,
                builder: (_, __) => const SubscriptionsScreen(),
                routes: [
                  GoRoute(
                    path: 'folders/:id',
                    builder: (_, state) => FolderDetailScreen(
                      folderId: int.parse(state.pathParameters['id']!),
                    ),
                  ),
                  GoRoute(
                    path: ':id',
                    builder: (_, state) => PodcastDetailScreen(
                      podcastId: int.parse(state.pathParameters['id']!),
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.downloads,
                builder: (_, __) => const DownloadsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );

  ref.onDispose(router.dispose);
  return router;
});
