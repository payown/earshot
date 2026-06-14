import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'core/background/background_tasks.dart';
import 'core/constants/playback.dart';
import 'core/providers/auto_refresh_provider.dart';
import 'core/providers/core_providers.dart';
import 'core/logging/log_providers.dart';
import 'core/logging/log_service.dart';
import 'core/router/app_router.dart';
import 'core/sharing/sharing_intent_gateway.dart';
import 'core/sharing/shared_file_provider.dart';
import 'core/theme/app_theme.dart';
import 'data/db/app_database.dart';
import 'features/downloads/presentation/providers/downloads_providers.dart';
import 'features/player/data/audio_handler.dart';
import 'features/player/data/audio_session_config.dart';
import 'features/player/presentation/providers/player_providers.dart';
import 'features/settings/data/app_settings_repository.dart';
import 'features/settings/presentation/providers/settings_providers.dart';
import 'features/subscriptions/presentation/providers/subscriptions_providers.dart';

final _log = Logger('main');

// Placeholder DSNs — replace with real values before beta build.
// These are safe to leave empty; Sentry/PostHog silently no-op with empty DSN.
const _sentryDsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');
const _posthogApiKey = String.fromEnvironment(
  'POSTHOG_API_KEY',
  defaultValue: '',
);
const _posthogHost = String.fromEnvironment(
  'POSTHOG_HOST',
  defaultValue: 'https://app.posthog.com',
);

// AudioService.init registers the media session with the OS and has been
// observed to stall on some devices; bound the wait so the app doesn't
// appear to hang forever before the first frame.
const _startupInitTimeout = Duration(seconds: 15);

class _AppInitializer extends ConsumerWidget {
  const _AppInitializer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(handlerSettingsAttachmentProvider);
    ref.watch(skipDurationsAttachmentProvider);
    ref.watch(positionTrackerProvider);
    ref.watch(queueAutoAdvanceProvider);
    ref.watch(episodeIdPersistenceProvider);
    ref.watch(playbackRestorationProvider);
    ref.watch(autoRefreshProvider);

    void _announceIfAuditEnabled(AsyncValue<String> next) {
      if (next case AsyncData(value: final message)) {
        final enabled = ref.read(downloadAuditEnabledProvider).value ?? false;
        if (enabled && context.mounted) {
          SemanticsService.sendAnnouncement(
            View.of(context),
            message,
            TextDirection.ltr,
          );
        }
      }
    }

    ref.listen(
      downloadAuditEventsProvider,
      (_, next) => _announceIfAuditEnabled(next),
    );
    ref.listen(
      feedRefreshAuditEventsProvider,
      (_, next) => _announceIfAuditEnabled(next),
    );

    return const EarshotApp();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // LogService must initialize first so the log sink is attached before any
  // fire-and-forget failures (below) can be logged.
  final logService = await LogService.init();

  // BG task registration (Workmanager) can stall on new iOS versions — run
  // fire-and-forget with a timeout so it never blocks the first frame.
  unawaited(
    BackgroundTaskService.initialize()
        .then((_) => BackgroundTaskService.scheduleAll())
        .timeout(const Duration(seconds: 5))
        .catchError((Object e, StackTrace st) {
          _log.warning(
            'Background task registration failed or timed out',
            e,
            st,
          );
        }),
  );

  // Crash reporting and analytics are opt-out (default on) per the privacy
  // settings screen, so check the user's choice before initializing either
  // SDK. The DB is opened here (lazily — cheap) and handed to the provider
  // override below so it isn't opened twice.
  final db = AppDatabase();
  final settingsRepo = AppSettingsRepositoryImpl(database: db);

  bool crashReportingEnabled;
  bool analyticsEnabled;
  try {
    // This is the first query against the database, so it's also where a
    // failed schema migration from an older build would surface. Drift runs
    // the entire onUpgrade chain on this first query regardless of which
    // table it targets, and once a migration step fails, user_version never
    // advances — the same failure repeats on every future launch until the
    // db file is removed.
    crashReportingEnabled = await settingsRepo.isCrashReportingEnabled();
    analyticsEnabled = await settingsRepo.isAnalyticsEnabled();
  } catch (error, stackTrace) {
    _log.severe(
      'Database failed to open or migrate on startup',
      error,
      stackTrace,
    );
    // Sentry isn't initialized on this path yet, so this is a safe no-op if
    // the SDK hasn't been set up — same assumption as _startApp below.
    await Sentry.captureException(error, stackTrace: stackTrace);
    await db.close();
    runApp(
      const _StartupErrorApp(
        title: "Earshot couldn't load your data.",
        body:
            "Earshot's local database could not be opened, possibly due to "
            'a failed update. Resetting local data will clear your '
            'subscriptions, queue, and listening history, but should let '
            'the app start again.',
        resetAction: _resetLocalDatabase,
      ),
    );
    return;
  }

  if (crashReportingEnabled && _sentryDsn.isNotEmpty) {
    // Initialize Sentry first so that a failure or timeout during audio init
    // below is still captured.
    await SentryFlutter.init(
      (options) {
        options
          ..dsn = _sentryDsn
          ..tracesSampleRate = 0
          ..attachScreenshot = false
          ..sendDefaultPii = false;
      },
      appRunner: () => _startApp(
        db: db,
        logService: logService,
        analyticsEnabled: analyticsEnabled,
      ),
    );
  } else {
    await _startApp(
      db: db,
      logService: logService,
      analyticsEnabled: analyticsEnabled,
    );
  }
}

/// Initializes the audio engine, starts analytics if enabled, and runs the
/// app. Runs inside [SentryFlutter.init]'s `appRunner` when crash reporting
/// is enabled, or directly from [main] otherwise — [Sentry.captureException]
/// below is a safe no-op in the latter case.
Future<void> _startApp({
  required AppDatabase db,
  required LogService logService,
  required bool analyticsEnabled,
}) async {
  // Configure the audio session for long-form spoken audio with AirPlay
  // enabled. Without this, iOS leaves the session on its default
  // .soloAmbient category, which doesn't offer AirPlay devices as routes.
  // Best-effort: a failure here shouldn't block startup since playback
  // still works on the device speaker either way.
  try {
    final session = await AudioSession.instance;
    await session.configure(earshotAudioSessionConfiguration);
  } catch (error, stackTrace) {
    _log.warning('Failed to configure audio session', error, stackTrace);
  }

  EarshotAudioHandler audioHandler;
  try {
    audioHandler = await AudioService.init(
      builder: EarshotAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'media.payown.earshot.audio',
        androidNotificationChannelName: 'Earshot',
        androidNotificationOngoing: true,
        fastForwardInterval: kSkipForwardDuration,
        rewindInterval: kSkipBackDuration,
      ),
    ).timeout(_startupInitTimeout);
  } catch (error, stackTrace) {
    _log.severe(
      'Audio engine failed to initialize within '
      '${_startupInitTimeout.inSeconds}s',
      error,
      stackTrace,
    );
    await Sentry.captureException(error, stackTrace: stackTrace);
    // No ProviderScope will be created on this path, so close the DB
    // ourselves rather than leaving it open for the life of the error
    // screen.
    await db.close();
    runApp(
      const _StartupErrorApp(
        title: "Earshot couldn't start.",
        body:
            'Please close and reopen the app. If this keeps '
            'happening, restarting your device may help.',
      ),
    );
    return;
  }

  if (_posthogApiKey.isNotEmpty && analyticsEnabled) {
    final config = PostHogConfig(_posthogApiKey)..host = _posthogHost;
    await Posthog().setup(config);
  }

  // Earshot may have been launched via "Open in Earshot" or "Share to
  // Earshot" for an OPML file. Best-effort: a failure here shouldn't block
  // startup, it just means the share is missed.
  List<String> initialOpmlPaths = const [];
  try {
    initialOpmlPaths = await ShareHandlerGateway().getInitialSharedFiles();
  } catch (error, stackTrace) {
    _log.warning('Failed to read initial shared media', error, stackTrace);
  }

  runApp(
    ProviderScope(
      overrides: [
        // overrideWith (not overrideWithValue) so ref.onDispose(db.close) is
        // re-registered against this ProviderScope, matching
        // appDatabaseProvider's own definition.
        appDatabaseProvider.overrideWith((ref) {
          ref.onDispose(db.close);
          return db;
        }),
        audioHandlerProvider.overrideWithValue(audioHandler),
        logServiceProvider.overrideWithValue(logService),
        initialSharedOpmlPathsProvider.overrideWithValue(initialOpmlPaths),
      ],
      child: const _AppInitializer(),
    ),
  );
}

/// Deletes the on-disk database and its WAL/SHM/journal sidecar files so the
/// next launch creates a fresh database via [AppDatabase.migration]'s
/// `onCreate`. This is the recovery action offered when the database fails
/// to open or migrate: once an `onUpgrade` step fails, `user_version` never
/// advances, so the same failure repeats on every relaunch, and removing the
/// file is the only way out short of reinstalling the app.
Future<void> _resetLocalDatabase() async {
  final dbFolder = await getApplicationDocumentsDirectory();
  for (final suffix in ['', '-wal', '-shm', '-journal']) {
    final file = File(p.join(dbFolder.path, 'earshot.db$suffix'));
    if (file.existsSync()) {
      await file.delete();
    }
  }
}

/// Shown when startup fails before the main app can run — either the audio
/// engine timed out within [_startupInitTimeout], or the local database
/// failed to open/migrate. Without these, the rest of the app cannot run, so
/// this is the most the app can offer.
class _StartupErrorApp extends StatefulWidget {
  const _StartupErrorApp({
    required this.title,
    required this.body,
    this.resetAction,
  });

  final String title;
  final String body;

  /// When non-null, shows a "Reset local data" action. Used for database
  /// failures: the same migration would otherwise fail again on every
  /// relaunch, and there is no way to recover without removing the db file.
  final Future<void> Function()? resetAction;

  @override
  State<_StartupErrorApp> createState() => _StartupErrorAppState();
}

class _StartupErrorAppState extends State<_StartupErrorApp> {
  static const _resetCompleteMessage =
      'Local data has been reset. Close and reopen Earshot to continue.';

  bool _resetting = false;
  bool _resetComplete = false;

  @override
  void initState() {
    super.initState();
    // This is the very first (and only) screen the user sees, with no prior
    // VoiceOver focus context, so announce it instead of waiting for a swipe.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SemanticsService.sendAnnouncement(
        View.of(context),
        '${widget.title} ${widget.body}',
        TextDirection.ltr,
      );
    });
  }

  Future<void> _handleReset() async {
    setState(() => _resetting = true);
    try {
      await widget.resetAction!();
      if (!mounted) return;
      setState(() {
        _resetting = false;
        _resetComplete = true;
      });
      SemanticsService.sendAnnouncement(
        View.of(context),
        _resetCompleteMessage,
        TextDirection.ltr,
      );
    } catch (error, stackTrace) {
      _log.severe('Failed to reset local database', error, stackTrace);
      if (!mounted) return;
      setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bodyText = _resetComplete ? _resetCompleteMessage : widget.body;
    return MaterialApp(
      title: 'Earshot',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      highContrastTheme: AppTheme.highContrastLight(),
      highContrastDarkTheme: AppTheme.highContrastDark(),
      themeMode: ThemeMode.system,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.error_outline,
                    size: 48,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                const SizedBox(height: 16),
                Semantics(
                  header: true,
                  label: widget.title,
                  child: ExcludeSemantics(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  bodyText,
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                if (widget.resetAction != null && !_resetComplete) ...[
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _resetting ? null : _handleReset,
                    child: Text(
                      _resetting ? 'Resetting...' : 'Reset local data',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EarshotApp extends ConsumerWidget {
  const EarshotApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'Earshot',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      highContrastTheme: AppTheme.highContrastLight(),
      highContrastDarkTheme: AppTheme.highContrastDark(),
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
