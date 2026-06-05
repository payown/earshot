import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/format_bytes.dart';
import '../../../../features/downloads/presentation/providers/downloads_providers.dart';
import '../providers/settings_providers.dart';

class DownloadsSettingsScreen extends ConsumerWidget {
  const DownloadsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(
        children: [
          _sectionHeader(context, 'Auto-management'),
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
          ListTile(
            title: const Text('Storage cap'),
            subtitle: Text(
              ref
                  .watch(storageCapBytesProvider)
                  .when(
                    data: _capLabel,
                    loading: () => 'Loading...',
                    error: (_, __) => 'Unknown',
                  ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showCapPicker(
              context,
              ref,
              ref.read(storageCapBytesProvider).value,
            ),
          ),
          const Divider(),
          const _StorageUsedTile(),
          const Divider(),
          _sectionHeader(context, 'Manual cleanup'),
          ListTile(
            title: const Text('Clear downloads older than...'),
            subtitle: const Text(
              'Delete episodes published before a chosen date',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showClearOlderThanPicker(context, ref),
          ),
          ListTile(
            title: Text(
              'Clear all downloads',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            onTap: () => _confirmClearAll(context, ref),
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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
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

  Future<void> _showClearOlderThanPicker(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final options = <(int, String)>[
      (7, '1 week'),
      (14, '2 weeks'),
      (30, '1 month'),
      (90, '3 months'),
    ];

    final chosen = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierLabel: 'Dismiss clear older downloads picker',
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Semantics(
                header: true,
                label: 'Clear downloads older than',
                child: ExcludeSemantics(
                  child: Text(
                    'Clear downloads older than',
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
            for (final (days, label) in options)
              ListTile(
                title: Text(label),
                onTap: () => Navigator.of(sheetContext).pop(days),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (chosen == null || !context.mounted) return;

    final label = options.firstWhere((o) => o.$1 == chosen).$2;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierLabel: 'Dismiss clear older downloads confirmation',
      builder: (dialogContext) => AlertDialog(
        title: Text('Clear downloads older than $label?'),
        content: Text(
          'All downloaded episodes published more than $label ago will be '
          'permanently removed. This cannot be undone.',
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
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final count = await ref
        .read(downloadManagerProvider)
        .deleteDownloadsOlderThan(chosen);
    ref.invalidate(totalDownloadBytesProvider);

    if (!context.mounted) return;
    final message = count == 0
        ? 'No downloads to clear'
        : '$count download${count == 1 ? '' : 's'} cleared';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      TextDirection.ltr,
    );
  }

  Future<void> _confirmClearAll(BuildContext context, WidgetRef ref) async {
    final totalBytes = ref.read(totalDownloadBytesProvider).value ?? 0;
    final sizeLabel = formatBytes(totalBytes);

    final confirmed = await showDialog<bool>(
      context: context,
      barrierLabel: 'Dismiss clear all downloads confirmation',
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear all downloads?'),
        content: Text(
          totalBytes > 0
              ? 'This permanently removes $sizeLabel of downloaded audio files. '
                    'It cannot be undone.'
              : 'This permanently removes all downloaded audio files. '
                    'It cannot be undone.',
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
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    await ref.read(downloadManagerProvider).deleteAllDownloads();
    ref.invalidate(totalDownloadBytesProvider);

    if (!context.mounted) return;
    const message = 'All downloads cleared';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text(message)));
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      TextDirection.ltr,
    );
  }
}

class _StorageUsedTile extends ConsumerWidget {
  const _StorageUsedTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(totalDownloadBytesProvider);
    final label = async.when(
      data: (bytes) => bytes == 0 ? 'No downloads' : formatBytes(bytes),
      loading: () => 'Calculating...',
      error: (_, __) => 'Unknown',
    );
    final semanticLabel = async.when(
      data: (bytes) {
        if (bytes == 0) return 'Downloads using no storage';
        final mb = bytes / (1024 * 1024);
        if (mb < 1024) {
          return 'Downloads using ${mb.toStringAsFixed(0)} megabytes';
        }
        final gb = mb / 1024;
        return 'Downloads using ${gb.toStringAsFixed(1)} gigabytes';
      },
      loading: () => 'Calculating storage used',
      error: (_, __) => 'Storage size unknown',
    );

    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: ListTile(
          title: const Text('Storage used'),
          subtitle: Text(label),
        ),
      ),
    );
  }
}

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

void _showCapPicker(BuildContext context, WidgetRef ref, int? current) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierLabel: 'Dismiss storage cap picker',
    builder: (_) {
      const options = <(int?, String)>[
        (524288000, '500 MB'),
        (1073741824, '1 GB'),
        (2147483648, '2 GB'),
        (5368709120, '5 GB'),
        (null, 'No limit'),
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
                label: 'Storage cap',
                child: ExcludeSemantics(
                  child: Text(
                    'Storage cap',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'When the cap is reached, the oldest downloaded episodes are '
                'deleted first.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            RadioGroup<int?>(
              groupValue: current,
              onChanged: (val) async {
                Navigator.of(context).pop();
                final label = _capLabel(val);
                await ref.read(storageCapBytesProvider.notifier).set(val);
                if (context.mounted) {
                  SemanticsService.sendAnnouncement(
                    View.of(context),
                    'Storage cap set to $label',
                    TextDirection.ltr,
                  );
                }
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (bytes, label) in options)
                    RadioListTile<int?>(
                      title: Text(label),
                      value: bytes,
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

String _retentionLabel(int? days) => switch (days) {
  7 => '1 week',
  14 => '2 weeks',
  30 => '1 month',
  90 => '3 months',
  _ => 'Forever',
};

String _capLabel(int? bytes) {
  if (bytes == null) return 'No limit';
  return formatBytes(bytes);
}
