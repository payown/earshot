import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/accessibility/announce.dart';
import '../providers/settings_providers.dart';

class InboxSettingsScreen extends ConsumerWidget {
  const InboxSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Inbox')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Inbox for included podcasts only'),
            subtitle: const Text(
              'Only show new episodes in the inbox for podcasts you explicitly include',
            ),
            value: ref.watch(inboxOptInOnlyProvider).value ?? false,
            onChanged: ref.watch(inboxOptInOnlyProvider).isLoading
                ? null
                : (val) async {
                    try {
                      await ref.read(inboxOptInOnlyProvider.notifier).set(val);
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          val
                              ? 'Inbox limited to included podcasts'
                              : 'Inbox showing all podcasts',
                          TextDirection.ltr,
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          'Could not update inbox setting',
                          TextDirection.ltr,
                        );
                      }
                    }
                  },
          ),
          SwitchListTile(
            title: const Text('Announce podcast name first'),
            subtitle: const Text(
              'VoiceOver reads the show name before the episode title in the inbox',
            ),
            value: ref.watch(podcastNameFirstProvider).value ?? false,
            onChanged: ref.watch(podcastNameFirstProvider).isLoading
                ? null
                : (val) async {
                    try {
                      await ref
                          .read(podcastNameFirstProvider.notifier)
                          .set(val);
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          val
                              ? 'Podcast name will be announced first'
                              : 'Episode title will be announced first',
                          TextDirection.ltr,
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          'Could not update inbox setting',
                          TextDirection.ltr,
                        );
                      }
                    }
                  },
          ),
          SwitchListTile(
            title: const Text('Mark as played when clearing from inbox'),
            subtitle: const Text(
              'Clearing an episode also marks it played so it counts toward your history',
            ),
            value:
                ref.watch(clearFromInboxAlsoMarksPlayedProvider).value ?? false,
            onChanged:
                ref.watch(clearFromInboxAlsoMarksPlayedProvider).isLoading
                ? null
                : (val) async {
                    try {
                      await ref
                          .read(
                            clearFromInboxAlsoMarksPlayedProvider.notifier,
                          )
                          .set(val);
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          val
                              ? 'Clearing from inbox will also mark as played'
                              : 'Clearing from inbox will not mark as played',
                          TextDirection.ltr,
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          'Could not update inbox setting',
                          TextDirection.ltr,
                        );
                      }
                    }
                  },
          ),
          ListTile(
            title: const Text('Default episodes per podcast in inbox'),
            subtitle: Text(
              ref
                  .watch(inboxDefaultMaxEpisodesProvider)
                  .when(
                    data: _inboxDefaultLabel,
                    loading: () => 'Loading...',
                    error: (_, __) => 'Unknown',
                  ),
            ),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => _showInboxDefaultPicker(
              context,
              ref,
              ref.read(inboxDefaultMaxEpisodesProvider).value,
            ),
          ),
        ],
      ),
    );
  }
}

// Uses a record wrapper (int?,) so null-from-dismiss is distinguishable
// from null-from-"No limit" selection.
Future<void> _showInboxDefaultPicker(
  BuildContext context,
  WidgetRef ref,
  int? current,
) async {
  const options = <(int?, String)>[
    (null, 'No limit'),
    (1, '1'),
    (3, '3'),
    (5, '5'),
    (10, '10'),
  ];

  final result = await showModalBottomSheet<(int?,)>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierLabel: 'Dismiss default episodes per podcast picker',
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Semantics(
              header: true,
              label: 'Default episodes per podcast in inbox',
              child: ExcludeSemantics(
                child: Text(
                  'Default episodes per podcast in inbox',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'When a podcast has more than this many episodes in the inbox, '
              'the oldest ones are removed. Removed episodes stay in the '
              "show's episode list.",
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
                for (final (max, label) in options)
                  RadioListTile<int?>(title: Text(label), value: max),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (result == null || !context.mounted) return;
  final chosen = result.$1;
  if (chosen == current) return;
  final label = _inboxDefaultLabel(chosen);
  await ref.read(inboxDefaultMaxEpisodesProvider.notifier).set(chosen);
  if (context.mounted) {
    announceAfterDismiss(
      View.of(context),
      'Default episodes per podcast set to $label',
    );
  }
}

String _inboxDefaultLabel(int? max) =>
    max == null ? 'No limit' : max.toString();
