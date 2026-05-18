import 'package:flutter/material.dart';

import 'quick_action_configurator_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
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
            child: const _SectionHeader(label: 'About'),
          ),
          const ListTile(
            title: Text('Version'),
            subtitle: Text('Phase 3 build'),
          ),
        ],
      ),
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

enum QuickActionContentType { episode, podcast }
