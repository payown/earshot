import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db/enums.dart';
import '../../features/downloads/presentation/screens/downloads_screen.dart';
import '../../features/downloads/presentation/screens/inbox_screen.dart';
import '../../features/feedback/presentation/screens/bug_report_screen.dart';
import '../../features/onboarding/presentation/screens/onboarding_screen.dart';
import '../../features/player/presentation/screens/player_screen.dart';
import '../../features/player/presentation/screens/queue_screen.dart';
import '../../features/search/domain/search_result.dart';
import '../../features/search/presentation/screens/opml_import_screen.dart';
import '../../features/search/presentation/screens/search_result_detail_screen.dart';
import '../../features/search/presentation/screens/search_screen.dart';
import '../../features/settings/data/app_settings_repository.dart';
import '../../features/settings/presentation/screens/accessibility_settings_screen.dart';
import '../../features/settings/presentation/screens/downloads_settings_screen.dart';
import '../../features/settings/presentation/screens/inbox_settings_screen.dart';
import '../../features/settings/presentation/screens/playback_settings_screen.dart';
import '../../features/settings/presentation/screens/privacy_settings_screen.dart';
import '../../features/settings/presentation/screens/quick_action_configurator_screen.dart';
import '../../features/settings/presentation/screens/quick_actions_settings_screen.dart';
import '../../features/settings/presentation/screens/settings_screen.dart';
import '../../features/settings/presentation/screens/subscriptions_settings_screen.dart';
import '../../features/stats/presentation/screens/stats_screen.dart';
import '../../features/folders/presentation/screens/folder_detail_screen.dart';
import '../../features/subscriptions/presentation/screens/add_podcast_screen.dart';
import '../../features/subscriptions/presentation/screens/all_podcasts_screen.dart';
import '../../features/subscriptions/presentation/screens/podcast_detail_screen.dart';
import '../../features/subscriptions/presentation/screens/podcast_settings_screen.dart';
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
  static const allPodcasts = '/subscriptions/all';
  static String podcastDetail(int id) => '/subscriptions/$id';
  static String podcastSettings(int id) => '/subscriptions/$id/settings';
  static String folderDetail(int id) => '/subscriptions/folders/$id';
  static const downloads = '/downloads';
  static const search = '/search';
  static const searchResult = '/search/result';
  static const addPodcast = '/add-podcast';
  static const player = '/player';
  static const settings = '/settings';
  static const settingsImportOpml = '/settings/import-opml';
  static const settingsSubscriptions = '/settings/subscriptions';
  static const settingsQuickActionsMenu = '/settings/quick-actions-menu';
  static const settingsInbox = '/settings/inbox';
  static const settingsPlayback = '/settings/playback';
  static const settingsAccessibility = '/settings/accessibility';
  static const settingsStats = '/settings/stats';
  static const settingsPrivacy = '/settings/privacy';
  static const settingsDownloads = '/settings/downloads';
  static String settingsQuickActions(String type) =>
      '/settings/quick-actions/$type';
  static const bugReport = '/bug-report';
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
        final isAllowedDuringOnboarding =
            state.matchedLocation.startsWith(AppRoutes.search) ||
            state.matchedLocation.startsWith(AppRoutes.addPodcast) ||
            state.matchedLocation.startsWith(AppRoutes.settingsImportOpml);
        if (!done && !atOnboarding && !isAllowedDuringOnboarding)
          return AppRoutes.onboarding;
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
        builder: (_, state) => SearchScreen(
          fromOnboarding: state.extra == true,
        ),
        routes: [
          GoRoute(
            path: 'result',
            parentNavigatorKey: _rootKey,
            // extra is lost on deep links and state restoration; fall back
            // to the search screen instead of crashing on the cast below.
            redirect: (_, state) => state.extra is (PodcastSearchResult, bool)
                ? null
                : AppRoutes.search,
            builder: (_, state) {
              final (result, fromOnboarding) =
                  state.extra! as (PodcastSearchResult, bool);
              return SearchResultDetailScreen(
                result: result,
                fromOnboarding: fromOnboarding,
              );
            },
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.addPodcast,
        parentNavigatorKey: _rootKey,
        builder: (_, state) => AddPodcastScreen(
          fromOnboarding: state.extra == true,
        ),
      ),
      GoRoute(
        path: AppRoutes.player,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const PlayerScreen(),
      ),
      GoRoute(
        path: AppRoutes.bugReport,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const BugReportScreen(),
      ),
      GoRoute(
        path: AppRoutes.settings,
        parentNavigatorKey: _rootKey,
        builder: (_, __) => const SettingsScreen(),
        routes: [
          GoRoute(
            path: 'import-opml',
            parentNavigatorKey: _rootKey,
            builder: (_, state) => OpmlImportScreen(
              fromOnboarding: state.extra == true,
            ),
          ),
          GoRoute(
            path: 'subscriptions',
            parentNavigatorKey: _rootKey,
            builder: (_, __) => const SubscriptionsSettingsScreen(),
          ),
          GoRoute(
            path: 'quick-actions-menu',
            parentNavigatorKey: _rootKey,
            builder: (_, __) => const QuickActionsSettingsScreen(),
          ),
          GoRoute(
            path: 'inbox',
            parentNavigatorKey: _rootKey,
            builder: (_, __) => const InboxSettingsScreen(),
          ),
          GoRoute(
            path: 'playback',
            parentNavigatorKey: _rootKey,
            builder: (_, __) => const PlaybackSettingsScreen(),
          ),
          GoRoute(
            path: 'accessibility',
            parentNavigatorKey: _rootKey,
            builder: (_, __) => const AccessibilitySettingsScreen(),
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
            path: 'downloads',
            parentNavigatorKey: _rootKey,
            builder: (_, __) => const DownloadsSettingsScreen(),
          ),
          GoRoute(
            path: 'quick-actions/:type',
            parentNavigatorKey: _rootKey,
            // values.byName throws on unknown names (bad or legacy deep
            // links); send those to the quick actions menu instead.
            redirect: (_, state) =>
                QuickActionContentType.values.asNameMap().containsKey(
                  state.pathParameters['type'],
                )
                ? null
                : AppRoutes.settingsQuickActionsMenu,
            builder: (_, state) {
              final contentType = QuickActionContentType.values
                  .asNameMap()[state.pathParameters['type']]!;
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
                    path: 'all',
                    builder: (_, __) => const AllPodcastsScreen(),
                  ),
                  GoRoute(
                    path: 'folders/:id',
                    // Non-numeric ids (bad deep links) crash int.parse;
                    // fall back to the library root.
                    redirect: (_, state) =>
                        int.tryParse(state.pathParameters['id'] ?? '') == null
                        ? AppRoutes.subscriptions
                        : null,
                    builder: (_, state) => FolderDetailScreen(
                      folderId: int.parse(state.pathParameters['id']!),
                    ),
                  ),
                  GoRoute(
                    path: ':id',
                    // Validates the shared :id for this route and its nested
                    // settings route.
                    redirect: (_, state) =>
                        int.tryParse(state.pathParameters['id'] ?? '') == null
                        ? AppRoutes.subscriptions
                        : null,
                    builder: (_, state) => PodcastDetailScreen(
                      podcastId: int.parse(state.pathParameters['id']!),
                    ),
                    routes: [
                      GoRoute(
                        path: 'settings',
                        parentNavigatorKey: _rootKey,
                        builder: (_, state) => PodcastSettingsScreen(
                          podcastId: int.parse(state.pathParameters['id']!),
                        ),
                      ),
                    ],
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
