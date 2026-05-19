import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'core/presentation/main_shell.dart';
import 'core/providers/core_providers.dart';
import 'core/theme/app_theme.dart';
import 'features/onboarding/presentation/screens/onboarding_screen.dart';
import 'features/player/data/audio_handler.dart';
import 'features/player/presentation/providers/player_providers.dart';
import 'features/settings/data/app_settings_repository.dart';

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
    ref.watch(positionTrackerProvider);
    ref.watch(queueAutoAdvanceProvider);
    return const EarshotApp();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final audioHandler = await AudioService.init(
    builder: EarshotAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'media.payown.earshot.audio',
      androidNotificationChannelName: 'Earshot',
      androidNotificationOngoing: true,
      fastForwardInterval: Duration(seconds: 30),
      rewindInterval: Duration(seconds: 15),
    ),
  );

  // Initialize PostHog (no-op if key is empty).
  if (_posthogApiKey.isNotEmpty) {
    final config = PostHogConfig(_posthogApiKey)..host = _posthogHost;
    await Posthog().setup(config);
  }

  // Initialize Sentry wrapping runApp so it captures Flutter errors.
  await SentryFlutter.init(
    (options) {
      options
        ..dsn = _sentryDsn
        ..tracesSampleRate = 0
        ..attachScreenshot = false
        ..sendDefaultPii = false;
    },
    appRunner: () => runApp(
      ProviderScope(
        overrides: [
          audioHandlerProvider.overrideWithValue(audioHandler),
        ],
        child: const _AppInitializer(),
      ),
    ),
  );
}

class EarshotApp extends ConsumerWidget {
  const EarshotApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Earshot',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      highContrastTheme: AppTheme.highContrastLight(),
      highContrastDarkTheme: AppTheme.highContrastDark(),
      themeMode: ThemeMode.system,
      home: const _HomeRouter(),
    );
  }
}

class _HomeRouter extends ConsumerWidget {
  const _HomeRouter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(appDatabaseProvider);
    return FutureBuilder<bool>(
      future: AppSettingsRepositoryImpl(database: db).isOnboardingComplete(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == true) {
          return const MainShell();
        }
        return const OnboardingScreen();
      },
    );
  }
}
