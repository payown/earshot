import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'features/player/data/audio_handler.dart';
import 'features/player/presentation/providers/player_providers.dart';
import 'features/subscriptions/presentation/screens/subscriptions_screen.dart';

// Ensure positionTrackerProvider is initialized at app start so it
// begins listening to playback state immediately.
class _AppInitializer extends ConsumerWidget {
  const _AppInitializer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(positionTrackerProvider);
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

  runApp(
    ProviderScope(
      overrides: [
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const _AppInitializer(),
    ),
  );
}

class EarshotApp extends StatelessWidget {
  const EarshotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Earshot',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      highContrastTheme: AppTheme.highContrastLight(),
      highContrastDarkTheme: AppTheme.highContrastDark(),
      themeMode: ThemeMode.system,
      home: const SubscriptionsScreen(),
    );
  }
}
