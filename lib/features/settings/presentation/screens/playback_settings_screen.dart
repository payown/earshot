import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/player/presentation/providers/player_providers.dart';
import '../../../../features/player/presentation/widgets/speed_selector.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';

class PlaybackSettingsScreen extends ConsumerWidget {
  const PlaybackSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skipFwdSecs = ref.watch(skipForwardSecondsProvider).value ?? 30;
    final skipBackSecs = ref.watch(skipBackSecondsProvider).value ?? 15;

    return Scaffold(
      appBar: AppBar(title: const Text('Playback')),
      body: ListView(
        children: [
          _sectionHeader(context, 'Speed'),
          ListTile(
            title: const Text('Default speed'),
            subtitle: const Text(
              'Used for podcasts with no per-podcast speed set',
            ),
            trailing: SizedBox(
              width: 160,
              child: SpeedSelector(
                speed: ref.watch(globalSpeedProvider).asData?.value ?? 1.0,
                onSpeedChanged: (speed) async {
                  await ref.read(globalSpeedProvider.notifier).set(speed);
                  if (context.mounted) {
                    SemanticsService.sendAnnouncement(
                      View.of(context),
                      'Default speed set to ${SpeedSelector.formatSpeed(speed)}',
                      TextDirection.ltr,
                    );
                  }
                },
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('Trim silence by default'),
            subtitle: const Text(
              'Used for podcasts with no per-podcast trim-silence setting',
            ),
            value: ref.watch(skipSilenceProvider).asData?.value ?? false,
            onChanged: ref.watch(skipSilenceProvider).isLoading
                ? null
                : (val) async {
                    await ref.read(skipSilenceProvider.notifier).set(val);
                    await ref
                        .read(audioHandlerProvider)
                        .setSkipSilenceEnabled(val);
                    if (context.mounted) {
                      SemanticsService.sendAnnouncement(
                        View.of(context),
                        val
                            ? 'Trim silence enabled by default'
                            : 'Trim silence disabled by default',
                        TextDirection.ltr,
                      );
                    }
                  },
          ),
          _sectionHeader(context, 'Skip intervals'),
          _SkipIntervalTile(
            label: 'Skip forward',
            currentSeconds: skipFwdSecs,
            onChanged: (secs) async {
              try {
                await ref.read(skipForwardSecondsProvider.notifier).set(secs);
                if (context.mounted) {
                  SemanticsService.sendAnnouncement(
                    View.of(context),
                    'Skip forward set to $secs seconds',
                    TextDirection.ltr,
                  );
                }
              } catch (_) {
                if (context.mounted) {
                  SemanticsService.sendAnnouncement(
                    View.of(context),
                    'Could not update skip forward setting',
                    TextDirection.ltr,
                  );
                }
              }
            },
          ),
          _SkipIntervalTile(
            label: 'Skip back',
            currentSeconds: skipBackSecs,
            onChanged: (secs) async {
              try {
                await ref.read(skipBackSecondsProvider.notifier).set(secs);
                if (context.mounted) {
                  SemanticsService.sendAnnouncement(
                    View.of(context),
                    'Skip back set to $secs seconds',
                    TextDirection.ltr,
                  );
                }
              } catch (_) {
                if (context.mounted) {
                  SemanticsService.sendAnnouncement(
                    View.of(context),
                    'Could not update skip back setting',
                    TextDirection.ltr,
                  );
                }
              }
            },
          ),
          _sectionHeader(context, 'Queue'),
          SwitchListTile(
            title: const Text('Group episodes by podcast'),
            subtitle: const Text('Groups your queue by show'),
            value: ref.watch(groupQueueEpisodesProvider).value ?? false,
            onChanged: ref.watch(groupQueueEpisodesProvider).isLoading
                ? null
                : (val) async {
                    try {
                      await ref
                          .read(groupQueueEpisodesProvider.notifier)
                          .set(val);
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          val ? 'Queue grouped by podcast' : 'Queue ungrouped',
                          TextDirection.ltr,
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          'Could not update queue setting',
                          TextDirection.ltr,
                        );
                      }
                    }
                  },
          ),
          SwitchListTile(
            title: const Text('Continue after queue ends'),
            subtitle: const Text(
              'When the queue finishes, keep playing instead of stopping',
            ),
            value: ref.watch(continueAfterQueueProvider).value ?? false,
            onChanged: ref.watch(continueAfterQueueProvider).isLoading
                ? null
                : (val) async {
                    try {
                      await ref
                          .read(continueAfterQueueProvider.notifier)
                          .set(val);
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          val
                              ? 'Playback will continue after queue ends'
                              : 'Playback will stop at end of queue',
                          TextDirection.ltr,
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          'Could not update queue setting',
                          TextDirection.ltr,
                        );
                      }
                    }
                  },
          ),
          SwitchListTile(
            title: const Text('Continue after group ends'),
            subtitle: const Text(
              'Keep playing when the group you started finishes',
            ),
            value: ref.watch(continueAfterGroupEndsProvider).value ?? true,
            onChanged: ref.watch(continueAfterGroupEndsProvider).isLoading
                ? null
                : (val) async {
                    try {
                      await ref
                          .read(continueAfterGroupEndsProvider.notifier)
                          .set(val);
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          val
                              ? 'Playback will continue after group ends'
                              : 'Playback will stop at end of group',
                          TextDirection.ltr,
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          'Could not update queue setting',
                          TextDirection.ltr,
                        );
                      }
                    }
                  },
          ),
          SwitchListTile(
            title: const Text('Gapless playback'),
            subtitle: const Text(
              'Seamlessly transitions between episodes with no silence between them',
            ),
            value: ref.watch(gaplessPlaybackProvider).value ?? true,
            onChanged: ref.watch(gaplessPlaybackProvider).isLoading
                ? null
                : (val) async {
                    try {
                      await ref.read(gaplessPlaybackProvider.notifier).set(val);
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          val
                              ? 'Gapless playback enabled'
                              : 'Gapless playback disabled',
                          TextDirection.ltr,
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          'Could not update playback setting',
                          TextDirection.ltr,
                        );
                      }
                    }
                  },
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Semantics(
        header: true,
        label: label,
        child: ExcludeSemantics(
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
}

class _SkipIntervalTile extends StatelessWidget {
  const _SkipIntervalTile({
    required this.label,
    required this.currentSeconds,
    required this.onChanged,
  });

  final String label;
  final int currentSeconds;
  final Future<void> Function(int seconds) onChanged;

  static const _options = [10, 15, 30, 45, 60, 90];

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label, $currentSeconds seconds',
      button: true,
      hint: 'Use the actions menu to change the interval',
      onTap: () {
        final nextIndex =
            (_options.indexOf(currentSeconds) + 1) % _options.length;
        onChanged(_options[nextIndex]);
      },
      customSemanticsActions: {
        for (final secs in _options)
          if (secs != currentSeconds)
            CustomSemanticsAction(label: '$secs seconds'): () =>
                onChanged(secs),
      },
      child: ExcludeSemantics(
        child: ListTile(
          title: Text(label),
          subtitle: Text('$currentSeconds seconds'),
          trailing: DropdownButton<int>(
            value: currentSeconds,
            underline: const SizedBox.shrink(),
            items: _options
                .map(
                  (s) => DropdownMenuItem(
                    value: s,
                    child: Text('${s}s'),
                  ),
                )
                .toList(),
            onChanged: (secs) {
              if (secs != null) onChanged(secs);
            },
          ),
        ),
      ),
    );
  }
}
