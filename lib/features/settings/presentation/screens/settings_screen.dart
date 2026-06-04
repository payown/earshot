import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../core/router/app_router.dart';
import '../../../../data/db/enums.dart';
import '../../../../features/folders/presentation/providers/folders_providers.dart';
import '../../../../features/player/presentation/providers/player_providers.dart';
import '../../../../features/search/presentation/providers/search_providers.dart';
import '../../../../features/settings/data/app_settings_repository.dart';
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
            label: 'Queue',
            child: const ExcludeSemantics(
              child: _SectionHeader(label: 'Queue'),
            ),
          ),
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
          ListTile(
            title: const Text('Keep downloads for'),
            subtitle: Text(
              ref
                  .watch(downloadRetentionDaysProvider)
                  .when(
                    data: _retentionLabel,
                    loading: () => 'Loading...',
                    error: (_, __) => 'Unknown',
                  ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showRetentionPicker(
              context,
              ref,
              ref.read(downloadRetentionDaysProvider).value,
            ),
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
          const _VersionTile(),
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

String _retentionLabel(int? days) => switch (days) {
  7 => '1 week',
  14 => '2 weeks',
  30 => '1 month',
  90 => '3 months',
  _ => 'Forever',
};

void _showRetentionPicker(BuildContext context, WidgetRef ref, int? current) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierLabel: 'Dismiss keep downloads picker',
    builder: (_) {
      final options = <(int?, String)>[
        (7, '1 week'),
        (14, '2 weeks'),
        (30, '1 month'),
        (90, '3 months'),
        (null, 'Forever'),
      ];
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Semantics(
                header: true,
                label: 'Keep downloads for',
                child: ExcludeSemantics(
                  child: Text(
                    'Keep downloads for',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
            RadioGroup<int?>(
              groupValue: current,
              onChanged: (val) async {
                Navigator.of(context).pop();
                final label = _retentionLabel(val);
                await ref.read(downloadRetentionDaysProvider.notifier).set(val);
                if (context.mounted) {
                  SemanticsService.sendAnnouncement(
                    View.of(context),
                    'Keep downloads set to $label',
                    TextDirection.ltr,
                  );
                }
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (days, label) in options)
                    RadioListTile<int?>(
                      title: Text(label),
                      value: days,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

class _VersionTile extends ConsumerStatefulWidget {
  const _VersionTile();

  @override
  ConsumerState<_VersionTile> createState() => _VersionTileState();
}

class _VersionTileState extends ConsumerState<_VersionTile> {
  int _tapCount = 0;

  static const _countdownMessages = {
    3: 'Tap 4 more times to enable developer mode',
    4: 'Tap 3 more times to enable developer mode',
    5: 'Tap 2 more times to enable developer mode',
    6: 'Tap 1 more time to enable developer mode',
  };

  void _onTap() {
    final newCount = _tapCount + 1;
    setState(() => _tapCount = newCount);

    final message = _countdownMessages[newCount];
    if (message != null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 2),
          ),
        );
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        TextDirection.ltr,
      );
      return;
    }

    if (newCount < 7) return;
    setState(() => _tapCount = 0);
    ScaffoldMessenger.of(context).clearSnackBars();
    _showDeveloperModeSheet();
  }

  void _showDeveloperModeSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierLabel: 'Dismiss developer mode',
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Semantics(
                header: true,
                label: 'Developer Mode',
                child: ExcludeSemantics(
                  child: Text(
                    'Developer Mode',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const ExcludeSemantics(
                child: Icon(Icons.restart_alt),
              ),
              title: const Text('Reset Onboarding'),
              subtitle: const Text('Show onboarding again on next launch'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _confirmResetOnboarding();
              },
            ),
            ListTile(
              leading: ExcludeSemantics(
                child: Icon(
                  Icons.delete_forever,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              title: Text(
                'Clear All App Data',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              subtitle: const Text(
                'Wipes everything and returns to onboarding',
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _confirmClearAllData();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmResetOnboarding() async {
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierLabel: 'Dismiss reset onboarding dialog',
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset Onboarding'),
        content: const Text(
          'This resets the onboarding flow. Restart the app to see it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    await AppSettingsRepositoryImpl(
      database: ref.read(appDatabaseProvider),
    ).setOnboardingComplete(complete: false);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Onboarding reset — restart to see it')),
      );
    }
  }

  Future<void> _confirmClearAllData() async {
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierLabel: 'Dismiss clear all data dialog',
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear All App Data?'),
        content: const Text(
          'This permanently deletes all podcasts, episodes, queue, bookmarks, '
          'stats, and settings. The app will return to onboarding. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear Everything'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    await ref.read(appDatabaseProvider).clearAllData();
    if (!context.mounted) return;

    ref.invalidate(isOnboardingCompleteProvider);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('Version'),
      subtitle: Text(
        ref
            .watch(packageInfoProvider)
            .when(
              data: (info) => '${info.version} (${info.buildNumber})',
              loading: () => 'Loading',
              error: (_, __) => 'Version unavailable',
            ),
      ),
      onTap: _onTap,
    );
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
