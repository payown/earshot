import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../core/router/app_router.dart';
import '../../../../features/settings/data/app_settings_repository.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Subscriptions'),
            subtitle: const Text('Import and export OPML'),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => context.push(AppRoutes.settingsSubscriptions),
          ),
          ListTile(
            title: const Text('Quick Actions'),
            subtitle: const Text('Episode and podcast quick actions'),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => context.push(AppRoutes.settingsQuickActionsMenu),
          ),
          ListTile(
            title: const Text('Inbox'),
            subtitle: const Text('Inbox filter and announcement order'),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => context.push(AppRoutes.settingsInbox),
          ),
          ListTile(
            title: const Text('Playback'),
            subtitle: const Text('Speed, skip intervals, queue, and gapless'),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => context.push(AppRoutes.settingsPlayback),
          ),
          ListTile(
            title: const Text('Stats'),
            subtitle: const Text('Time listened, speed savings, history'),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => context.push(AppRoutes.settingsStats),
          ),
          ListTile(
            title: const Text('Privacy'),
            subtitle: const Text('History retention, delete all data'),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => context.push(AppRoutes.settingsPrivacy),
          ),
          ListTile(
            title: const Text('Downloads'),
            subtitle: const Text('Storage, cleanup, and Wi-Fi settings'),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => context.push(AppRoutes.settingsDownloads),
          ),
          ListTile(
            title: const Text('Accessibility'),
            subtitle: const Text('Direct Touch Mode and assistive options'),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => context.push(AppRoutes.settingsAccessibility),
          ),
          const Divider(),
          const _VersionTile(),
          const ListTile(
            title: Text('Podcast search powered by Podcast Index'),
            subtitle: Text('podcastindex.org'),
          ),
        ],
      ),
    );
  }
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
      builder: (sheetContext) => Consumer(
        builder: (_, consumerRef, __) {
          final auditEnabled =
              consumerRef.watch(downloadAuditEnabledProvider).value ?? false;
          return SafeArea(
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
                  leading: const ExcludeSemantics(
                    child: Icon(Icons.tips_and_updates_outlined),
                  ),
                  title: const Text('Reset Tips'),
                  subtitle: const Text(
                    'Show tip cards again in Inbox and Queue',
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_resetTips());
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
                SwitchListTile(
                  secondary: const ExcludeSemantics(
                    child: Icon(Icons.volume_up_outlined),
                  ),
                  title: const Text('Download audit announcements'),
                  subtitle: const Text(
                    'Announce feed checks and completed downloads',
                  ),
                  value: auditEnabled,
                  onChanged: (v) => consumerRef
                      .read(downloadAuditEnabledProvider.notifier)
                      .set(v),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _resetTips() async {
    await ref.read(podcastNameTipSeenProvider.notifier).set(false);
    await ref.read(gaplessTipSeenProvider.notifier).set(false);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tips reset — visit Inbox and Queue to see them'),
        ),
      );
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Tips reset',
        TextDirection.ltr,
      );
    }
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
    final versionText = ref
        .watch(packageInfoProvider)
        .when(
          data: (info) => '${info.version} (${info.buildNumber})',
          loading: () => 'Loading',
          error: (_, __) => 'Version unavailable',
        );

    return Semantics(
      button: true,
      label: 'Version $versionText',
      hint: 'Tap repeatedly to unlock developer menu',
      onTap: _onTap,
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        const CustomSemanticsAction(label: 'Open developer menu'):
            _showDeveloperModeSheet,
      },
      child: ExcludeSemantics(
        child: ListTile(
          title: const Text('Version'),
          subtitle: Text(versionText),
          onTap: _onTap,
        ),
      ),
    );
  }
}
