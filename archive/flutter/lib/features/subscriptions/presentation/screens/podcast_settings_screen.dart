import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/accessibility/announce.dart';
import '../../../../core/constants/spacing.dart';
import '../../../../features/downloads/presentation/providers/downloads_providers.dart';
import '../../../../features/player/presentation/providers/player_providers.dart';
import '../../../../features/player/presentation/widgets/speed_selector.dart';
import '../../../settings/presentation/providers/settings_providers.dart';
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
    final hasOverride = podcast.hasPlaybackOverride;

    // Resolve the global default so "Use default" can name the value it follows
    // (e.g. "Use default (3)"). Fall back to a plain label while it loads.
    final globalDefault = ref.watch(inboxDefaultMaxEpisodesProvider);
    final useDefaultLabel = globalDefault.maybeWhen(
      data: (max) =>
          'Use default (${max == null ? 'No limit' : max.toString()})',
      orElse: () => 'Use default',
    );

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
          const Divider(),
          _sectionHeader(context, 'Inbox'),
          ListTile(
            title: const Text('Episodes in inbox'),
            subtitle: Text(
              _maxEpisodesLabel(podcast.inboxMaxEpisodes, useDefaultLabel),
            ),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => _showMaxEpisodesPicker(context, ref, useDefaultLabel),
          ),
          ListTile(
            title: const Text('Remove from inbox after'),
            subtitle: Text(_ageLimitLabel(podcast.inboxAgeLimitHours)),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => _showAgeLimitPicker(context, ref),
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

  // Uses a record wrapper (int?,) so null-from-dismiss is distinguishable
  // from null-from-"Use default" selection.
  Future<void> _showMaxEpisodesPicker(
    BuildContext context,
    WidgetRef ref,
    String useDefaultLabel,
  ) async {
    final current = podcast.inboxMaxEpisodes;
    final options = <(int?, String)>[
      (null, useDefaultLabel),
      (1, '1'),
      (3, '3'),
      (5, '5'),
      (10, '10'),
    ];

    final result = await showModalBottomSheet<(int?,)>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierLabel: 'Dismiss episodes in inbox picker',
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.lg,
                Spacing.md,
                Spacing.sm,
              ),
              child: Semantics(
                header: true,
                label: 'Episodes in inbox',
                child: ExcludeSemantics(
                  child: Text(
                    'Episodes in inbox',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                0,
                Spacing.md,
                Spacing.sm,
              ),
              child: Text(
                'Use default follows the global Inbox setting. When a podcast '
                'has more than this many episodes in the inbox, the oldest '
                "ones are removed. Removed episodes stay in the show's episode "
                'list, so nothing is deleted.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            RadioGroup<int?>(
              groupValue: current,
              onChanged: (val) => Navigator.of(context).pop((val,)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (value, label) in options)
                    RadioListTile<int?>(title: Text(label), value: value),
                ],
              ),
            ),
            const SizedBox(height: Spacing.sm),
          ],
        ),
      ),
    );

    if (result == null || !context.mounted) return;
    final chosen = result.$1;
    if (chosen == current) return;
    await ref
        .read(podcastRepositoryProvider)
        .setInboxMaxEpisodes(
          podcast.id,
          chosen,
        );
    await ref.read(inboxLimitServiceProvider).applyForPodcast(podcast.id);
    if (context.mounted) {
      announceAfterDismiss(
        View.of(context),
        'Episodes in inbox set to ${_maxEpisodesLabel(chosen, useDefaultLabel)}',
      );
    }
  }

  Future<void> _showAgeLimitPicker(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final current = podcast.inboxAgeLimitHours;
    const options = <(int?, String)>[
      (null, 'Off'),
      (6, '6 hours'),
      (12, '12 hours'),
      (24, '1 day'),
      (72, '3 days'),
      (168, '1 week'),
      (336, '2 weeks'),
    ];

    final result = await showModalBottomSheet<(int?,)>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierLabel: 'Dismiss remove from inbox after picker',
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.lg,
                Spacing.md,
                Spacing.sm,
              ),
              child: Semantics(
                header: true,
                label: 'Remove from inbox after',
                child: ExcludeSemantics(
                  child: Text(
                    'Remove from inbox after',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                0,
                Spacing.md,
                Spacing.sm,
              ),
              child: Text(
                'Off keeps episodes in the inbox until you clear them. '
                'Otherwise, episodes older than this are removed from the '
                "inbox. Removed episodes stay in the show's episode list, so "
                'nothing is deleted.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            RadioGroup<int?>(
              groupValue: current,
              onChanged: (val) => Navigator.of(context).pop((val,)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (value, label) in options)
                    RadioListTile<int?>(title: Text(label), value: value),
                ],
              ),
            ),
            const SizedBox(height: Spacing.sm),
          ],
        ),
      ),
    );

    if (result == null || !context.mounted) return;
    final chosen = result.$1;
    if (chosen == current) return;
    await ref
        .read(podcastRepositoryProvider)
        .setInboxAgeLimitHours(
          podcast.id,
          chosen,
        );
    await ref.read(inboxLimitServiceProvider).applyForPodcast(podcast.id);
    if (context.mounted) {
      announceAfterDismiss(
        View.of(context),
        'Remove from inbox after set to ${_ageLimitLabel(chosen)}',
      );
    }
  }
}

String _maxEpisodesLabel(int? max, String useDefaultLabel) =>
    max == null ? useDefaultLabel : '$max';

String _ageLimitLabel(int? hours) => switch (hours) {
  null => 'Off',
  6 => '6 hours',
  12 => '12 hours',
  24 => '1 day',
  72 => '3 days',
  168 => '1 week',
  336 => '2 weeks',
  _ => '$hours hours',
};
