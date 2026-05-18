import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../features/search/presentation/providers/search_providers.dart';
import '../../../../features/search/presentation/screens/opml_import_screen.dart';
import '../../../../features/stats/presentation/screens/stats_screen.dart';
import '../../../../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'privacy_settings_screen.dart';
import 'quick_action_configurator_screen.dart';

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
            child: const _SectionHeader(label: 'Subscriptions'),
          ),
          ListTile(
            title: const Text('Import OPML'),
            subtitle: const Text('Import subscriptions from another app'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const OpmlImportScreen(),
              ),
            ),
          ),
          ListTile(
            title: const Text('Export OPML'),
            subtitle: const Text('Share your subscriptions list'),
            trailing: const Icon(Icons.share),
            onTap: () => _exportOpml(context, ref),
          ),
          const Divider(),
          Semantics(
            header: true,
            child: const _SectionHeader(label: 'Quick Actions'),
          ),
          ListTile(
            title: const Text('Episode Quick Actions'),
            subtitle: const Text('Choose and reorder actions on episodes'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const QuickActionConfiguratorScreen(
                  contentType: QuickActionContentType.episode,
                ),
              ),
            ),
          ),
          ListTile(
            title: const Text('Podcast Quick Actions'),
            subtitle: const Text('Choose and reorder actions on podcasts'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const QuickActionConfiguratorScreen(
                  contentType: QuickActionContentType.podcast,
                ),
              ),
            ),
          ),
          const Divider(),
          Semantics(
            header: true,
            child: const _SectionHeader(label: 'Stats'),
          ),
          ListTile(
            title: const Text('Listening Stats'),
            subtitle: const Text('Time listened, speed savings, history'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const StatsScreen(),
              ),
            ),
          ),
          const Divider(),
          Semantics(
            header: true,
            child: const _SectionHeader(label: 'Privacy'),
          ),
          ListTile(
            title: const Text('Privacy & History'),
            subtitle: const Text('History retention, delete all data'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const PrivacySettingsScreen(),
              ),
            ),
          ),
          const Divider(),
          Semantics(
            header: true,
            child: const _SectionHeader(label: 'About'),
          ),
          const ListTile(
            title: Text('Version'),
            subtitle: Text('Phase 6 build'),
          ),
        ],
      ),
    );
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

enum QuickActionContentType { episode, podcast }
