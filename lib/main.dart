import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'core/background/background_tasks.dart';
import 'core/constants/playback.dart';
import 'core/providers/auto_refresh_provider.dart';
import 'core/logging/log_providers.dart';
import 'core/logging/log_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/downloads/presentation/providers/downloads_providers.dart';
import 'features/player/data/audio_handler.dart';
import 'features/player/presentation/providers/player_providers.dart';
import 'features/settings/presentation/providers/settings_providers.dart';
import 'features/subscriptions/presentation/providers/subscriptions_providers.dart';

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

  // BG task registration (Workmanager) can stall on new iOS versions — run
  // fire-and-forget with a timeout so it never blocks the first frame.
  unawaited(
    BackgroundTaskService.initialize()
        .then((_) => BackgroundTaskService.scheduleAll())
        .timeout(const Duration(seconds: 5))
        .catchError((Object _) {}),
  );

  final (audioHandler, logService) = await (
    AudioService.init(
      builder: EarshotAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'media.payown.earshot.audio',
        androidNotificationChannelName: 'Earshot',
        androidNotificationOngoing: true,
        fastForwardInterval: kSkipForwardDuration,
        rewindInterval: kSkipBackDuration,
      ),
    ),
    LogService.init(),
  ).wait;

  if (_posthogApiKey.isNotEmpty) {
    final config = PostHogConfig(_posthogApiKey)..host = _posthogHost;
    await Posthog().setup(config);
  }

  void launchApp() => runApp(
    ProviderScope(
      overrides: [
        audioHandlerProvider.overrideWithValue(audioHandler),
        logServiceProvider.overrideWithValue(logService),
      ],
      child: const _AppInitializer(),
    ),
  );

  if (_sentryDsn.isNotEmpty) {
    await SentryFlutter.init(
      (options) {
        options
          ..dsn = _sentryDsn
          ..tracesSampleRate = 0
          ..attachScreenshot = false
          ..sendDefaultPii = false;
      },
      appRunner: launchApp,
    );
  } else {
    launchApp();
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
