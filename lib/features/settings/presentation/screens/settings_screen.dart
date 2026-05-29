import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/router/app_router.dart';
import '../../../../data/db/enums.dart';
import '../../../../features/folders/presentation/providers/folders_providers.dart';
import '../../../../features/player/presentation/providers/player_providers.dart';
import '../../../../features/search/presentation/providers/search_providers.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';
import '../../../../features/subscriptions/presentation/providers/subscriptions_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          Semantics(
            header: true,
            label: 'Subscriptions',
            child: const ExcludeSemantics(
              child: _SectionHeader(label: 'Subscriptions'),
            ),
          ),
          ListTile(
            title: const Text('Import OPML'),
            subtitle: const Text('Import subscriptions from another app'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.settingsImportOpml),
          ),
          ListTile(
            title: const Text('Export OPML'),
            subtitle: const Text('Share your subscriptions list'),
            trailing: const Icon(Icons.share),
            onTap: () => _exportOpml(context, ref),
          ),
          ListTile(
            title: const Text('Export OPML with folders'),
            subtitle: const Text('Share subscriptions grouped by folder'),
            trailing: const Icon(Icons.share),
            onTap: () => _exportOpmlWithFolders(context, ref),
          ),
          const Divider(),
          Semantics(
            header: true,
            label: 'Quick Actions',
            child: const ExcludeSemantics(
              child: _SectionHeader(label: 'Quick Actions'),
            ),
          ),
          ListTile(
            title: const Text('Episode Quick Actions'),
            subtitle: const Text('Choose and reorder actions on episodes'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(
              AppRoutes.settingsQuickActions(
                QuickActionContentType.episode.name,
              ),
            ),
          ),
          ListTile(
            title: const Text('Podcast Quick Actions'),
            subtitle: const Text('Choose and reorder actions on podcasts'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(
              AppRoutes.settingsQuickActions(
                QuickActionContentType.podcast.name,
              ),
            ),
          ),
          const Divider(),
          Semantics(
            header: true,
            label: 'Inbox',
            child: const ExcludeSemantics(
              child: _SectionHeader(label: 'Inbox'),
            ),
          ),
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
          const Divider(),
          Semantics(
            header: true,
            label: 'Stats',
            child: const ExcludeSemantics(
              child: _SectionHeader(label: 'Stats'),
            ),
          ),
          ListTile(
            title: const Text('Listening Stats'),
            subtitle: const Text('Time listened, speed savings, history'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.settingsStats),
          ),
          const Divider(),
          Semantics(
            header: true,
            label: 'Privacy',
            child: const ExcludeSemantics(
              child: _SectionHeader(label: 'Privacy'),
            ),
          ),
          ListTile(
            title: const Text('Privacy & History'),
            subtitle: const Text('History retention, delete all data'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(AppRoutes.settingsPrivacy),
          ),
          const ListTile(
            title: Text('Search Privacy'),
            subtitle: Text(
              'When you search for podcasts, your search terms are sent to '
              'the Podcast Index API (podcastindex.org). No account or '
              'personal information is shared.',
            ),
          ),
          const Divider(),
          Semantics(
            header: true,
            label: 'Downloads',
            child: const ExcludeSemantics(
              child: _SectionHeader(label: 'Downloads'),
            ),
          ),
          SwitchListTile(
            title: const Text('Download over Wi-Fi only'),
            subtitle: const Text(
              'When off, episodes can download over cellular data',
            ),
            value: ref.watch(wifiOnlyDownloadsProvider).value ?? true,
            onChanged: ref.watch(wifiOnlyDownloadsProvider).isLoading
                ? null
                : (val) async {
                    try {
                      await ref
                          .read(wifiOnlyDownloadsProvider.notifier)
                          .set(val);
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          val
                              ? 'Wi-Fi only downloads enabled'
                              : 'Downloads allowed on any network',
                          TextDirection.ltr,
                        );
                      }
                    } catch (_) {
                      if (context.mounted) {
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          'Could not update download setting',
                          TextDirection.ltr,
                        );
                      }
                    }
                  },
          ),
          const Divider(),
          Semantics(
            header: true,
            label: 'Accessibility',
            child: const ExcludeSemantics(
              child: _SectionHeader(label: 'Accessibility'),
            ),
          ),
          SwitchListTile(
            title: const Text('Direct Touch Mode'),
            subtitle: const Text(
              'Enables gesture controls on the artwork area for VoiceOver and TalkBack users',
            ),
            value: ref.watch(directTouchEnabledProvider).value ?? false,
            onChanged: ref.watch(directTouchEnabledProvider).isLoading
                ? null
                : (val) {
                    ref.read(directTouchEnabledProvider.notifier).set(val);
                    SemanticsService.sendAnnouncement(
                      View.of(context),
                      val
                          ? 'Direct Touch Mode enabled'
                          : 'Direct Touch Mode disabled',
                      TextDirection.ltr,
                    );
                  },
          ),
          const Divider(),
          Semantics(
            header: true,
            label: 'About',
            child: const ExcludeSemantics(
              child: _SectionHeader(label: 'About'),
            ),
          ),
          const ListTile(
            title: Text('Version'),
            subtitle: Text('Phase 6 build'),
          ),
          const ListTile(
            title: Text('Podcast search powered by Podcast Index'),
            subtitle: Text('podcastindex.org'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportOpmlWithFolders(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final groups = await ref
        .read(folderRepositoryProvider)
        .getAllWithFolderStructure();

    final hasContent = groups.any((g) => g.podcasts.isNotEmpty);
    if (!hasContent) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No subscriptions to export.')),
        );
      }
      return;
    }

    final xml = ref.read(opmlServiceProvider).generateWithFolders(groups);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/earshot-subscriptions-folders.opml');
    await file.writeAsString(xml);

    if (context.mounted) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/x-opml')],
          subject: 'Earshot Subscriptions',
        ),
      );
    }
  }

  Future<void> _exportOpml(BuildContext context, WidgetRef ref) async {
    final podcasts = ref.read(subscriptionsProvider).asData?.value ?? [];
    if (podcasts.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No subscriptions to export.')),
        );
      }
      return;
    }

    final subs = podcasts
        .map((p) => (rssUrl: p.rssUrl, title: p.title))
        .toList();
    final xml = ref.read(opmlServiceProvider).generate(subs);

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/earshot-subscriptions.opml');
    await file.writeAsString(xml);

    if (context.mounted) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/x-opml')],
          subject: 'Earshot Subscriptions',
        ),
      );
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
