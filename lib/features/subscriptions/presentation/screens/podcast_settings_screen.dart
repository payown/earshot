import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/spacing.dart';
import '../../../../features/player/presentation/providers/player_providers.dart';
import '../../../../features/player/presentation/widgets/speed_selector.dart';
import '../../domain/podcast.dart';
import '../providers/subscriptions_providers.dart';

class PodcastSettingsScreen extends ConsumerWidget {
  const PodcastSettingsScreen({required this.podcastId, super.key});

  final int podcastId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final podcastAsync = ref.watch(podcastProvider(podcastId));

    return podcastAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Error: $e')),
      ),
      data: (podcast) {
        if (podcast == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Podcast not found.')),
          );
        }
        return _PodcastSettingsView(podcast: podcast);
      },
    );
  }
}

class _PodcastSettingsView extends ConsumerWidget {
  const _PodcastSettingsView({required this.podcast});

  final Podcast podcast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasOverride = podcast.hasCustomSettings;

    return Scaffold(
      appBar: AppBar(title: Text('${podcast.title} Settings')),
      body: ListView(
        children: [
          _sectionHeader(context, 'Playback'),
          ListTile(
            title: const Text('Playback speed'),
            subtitle: Text(
              hasOverride
                  ? '${SpeedSelector.formatSpeed(podcast.speedOverride!)} (custom)'
                  : 'Global',
            ),
            trailing: hasOverride
                ? Semantics(
                    button: true,
                    label: 'Reset playback speed to global',
                    child: ExcludeSemantics(
                      child: OutlinedButton(
                        onPressed: () => _resetSpeed(context, ref),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Spacing.sm,
                          ),
                          minimumSize: const Size(
                            Spacing.minTouchTarget,
                            Spacing.minTouchTarget,
                          ),
                        ),
                        child: const Text('Reset'),
                      ),
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String label) {
    return Semantics(
      header: true,
      label: label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md,
            Spacing.md,
            Spacing.md,
            Spacing.xs,
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _resetSpeed(BuildContext context, WidgetRef ref) async {
    await ref.read(podcastRepositoryProvider).disableCustomSettings(podcast.id);
    // If this podcast's episode is currently playing, apply the global values
    // to the audio session immediately rather than waiting for the next load.
    final currentPodcastId =
        ref.read(mediaItemProvider).asData?.value?.extras?['podcastId'] as int?;
    if (currentPodcastId == podcast.id) {
      final handler = ref.read(audioHandlerProvider);
      final globalSpeed = await ref.read(globalSpeedProvider.future);
      final globalTrimSilence = await ref.read(skipSilenceProvider.future);
      await handler.setSpeed(globalSpeed);
      await handler.setSkipSilenceEnabled(globalTrimSilence);
    }
  }
}
