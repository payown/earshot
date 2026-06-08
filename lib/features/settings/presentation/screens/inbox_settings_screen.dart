import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
        ],
      ),
    );
  }
}
