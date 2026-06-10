import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'core/background/background_tasks.dart';
import 'core/constants/playback.dart';
import 'core/providers/auto_refresh_provider.dart';
import 'core/providers/core_providers.dart';
import 'core/logging/log_providers.dart';
import 'core/logging/log_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'data/db/app_database.dart';
import 'features/downloads/presentation/providers/downloads_providers.dart';
import 'features/player/data/audio_handler.dart';
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
  final crashReportingEnabled = await settingsRepo.isCrashReportingEnabled();
  final analyticsEnabled = await settingsRepo.isAnalyticsEnabled();

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
    runApp(const _StartupErrorApp());
    return;
  }

  if (_posthogApiKey.isNotEmpty && analyticsEnabled) {
    final config = PostHogConfig(_posthogApiKey)..host = _posthogHost;
    await Posthog().setup(config);
  }

  runApp(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        audioHandlerProvider.overrideWithValue(audioHandler),
        logServiceProvider.overrideWithValue(logService),
      ],
      child: const _AppInitializer(),
    ),
  );
}

/// Shown when the audio engine failed to initialize within
/// [_startupInitTimeout]. Without an [EarshotAudioHandler] the rest of the
/// app cannot run, so this is the most the app can offer.
class _StartupErrorApp extends StatefulWidget {
  const _StartupErrorApp();

  @override
  State<_StartupErrorApp> createState() => _StartupErrorAppState();
}

class _StartupErrorAppState extends State<_StartupErrorApp> {
  static const _title = "Earshot couldn't start.";
  static const _body =
      'Please close and reopen the app. If this keeps '
      'happening, restarting your device may help.';

  @override
  void initState() {
    super.initState();
    // This is the very first (and only) screen the user sees, with no prior
    // VoiceOver focus context, so announce it instead of waiting for a swipe.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SemanticsService.sendAnnouncement(
        View.of(context),
        '$_title $_body',
        TextDirection.ltr,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
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
                  label: _title,
                  child: ExcludeSemantics(
                    child: Text(
                      _title,
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _body,
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
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
