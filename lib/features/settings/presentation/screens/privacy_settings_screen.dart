import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../features/stats/data/stats_repository.dart';
import '../../../../features/stats/presentation/providers/stats_providers.dart';
import '../../data/app_settings_repository.dart';

class PrivacySettingsScreen extends ConsumerStatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  ConsumerState<PrivacySettingsScreen> createState() =>
      _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends ConsumerState<PrivacySettingsScreen> {
  int? _retentionDays;
  bool _crashReporting = true;
  bool _analytics = true;
  bool _loaded = false;

  static const _options = <String, int?>{
    'Don\'t keep': 0,
    '30 days': 30,
    '90 days': 90,
    '1 year': 365,
    'Keep forever': null,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final settings = AppSettingsRepositoryImpl(database: db);
    final days = await settings.getHistoryRetentionDays();
    final crash = await settings.isCrashReportingEnabled();
    final analytics = await settings.isAnalyticsEnabled();
    if (mounted) {
      setState(() {
        _retentionDays = days;
        _crashReporting = crash;
        _analytics = analytics;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final currentLabel = _options.entries
        .firstWhere(
          (e) => e.value == _retentionDays,
          orElse: () => const MapEntry('90 days', 90),
        )
        .key;

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & History')),
      body: ListView(
        children: [
          Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                'Crash Reports & Analytics',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('Crash reports'),
            subtitle: const Text(
              'Anonymized crash data to help fix bugs. Never contains your '
              'podcasts or listening history. Takes effect next time you '
              'restart Earshot.',
            ),
            value: _crashReporting,
            onChanged: (v) async {
              setState(() => _crashReporting = v);
              await AppSettingsRepositoryImpl(
                database: ref.read(appDatabaseProvider),
              ).setCrashReportingEnabled(enabled: v);
            },
          ),
          SwitchListTile(
            title: const Text('Anonymous analytics'),
            subtitle: const Text(
              'Feature usage counts only. Never contains search queries, '
              'episode titles, or personal data. Takes effect next time you '
              'restart Earshot.',
            ),
            value: _analytics,
            onChanged: (v) async {
              setState(() => _analytics = v);
              await AppSettingsRepositoryImpl(
                database: ref.read(appDatabaseProvider),
              ).setAnalyticsEnabled(enabled: v);
            },
          ),
          const Divider(),
          Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                'Listening History',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
          ListTile(
            title: const Text('Keep history for'),
            subtitle: Text(currentLabel),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showRetentionPicker(context),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Listening history is stored only on this device.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(),
          ListTile(
            title: Text(
              'Delete all listening history',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            onTap: () => _confirmDeleteAll(context),
          ),
        ],
      ),
    );
  }

  Future<void> _showRetentionPicker(BuildContext context) async {
    final chosen = await showDialog<int?>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Keep history for'),
        children: _options.entries
            .map(
              (e) => ListTile(
                leading: e.value == _retentionDays
                    ? const Icon(Icons.check)
                    : const SizedBox(width: 24),
                title: Text(e.key),
                onTap: () => Navigator.of(context).pop(e.value),
              ),
            )
            .toList(),
      ),
    );
    if (chosen == _retentionDays) return;
    if (!mounted) return;

    final db = ref.read(appDatabaseProvider);
    await AppSettingsRepositoryImpl(
      database: db,
    ).setHistoryRetentionDays(chosen);
    if (chosen == 0) {
      await StatsRepositoryImpl(database: db).deleteAllHistory();
    }
    if (mounted) setState(() => _retentionDays = chosen);
  }

  Future<void> _confirmDeleteAll(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete all history?'),
        content: const Text(
          'This permanently removes all your listening history. It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(statsRepositoryProvider).deleteAllHistory();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Listening history deleted.')),
      );
    }
  }
}
