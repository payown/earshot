import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../../../core/sharing/shared_file_provider.dart';
import '../../../../features/subscriptions/data/podcast_exception.dart';
import '../../../../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import '../providers/search_providers.dart';

final _log = Logger('OpmlImport');

class OpmlImportScreen extends ConsumerStatefulWidget {
  const OpmlImportScreen({super.key, this.fromOnboarding = false});

  final bool fromOnboarding;

  @override
  ConsumerState<OpmlImportScreen> createState() => _OpmlImportScreenState();
}

class _OpmlImportScreenState extends ConsumerState<OpmlImportScreen> {
  /// Pause after the "Opened from share" announcement so VoiceOver finishes
  /// speaking it before the import progress live region starts updating.
  static const _shareAnnouncementDelay = Duration(milliseconds: 300);

  bool _importing = false;
  int _total = 0;
  int _done = 0;
  int _skipped = 0;
  int _followed = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _processSharedQueue());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import OPML')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Import subscriptions from another podcast app. '
              'Select an OPML file (.opml or .xml).',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            if (_importing) ...[
              Semantics(
                liveRegion: true,
                label: 'Importing: $_done of $_total',
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: _total > 0 ? _done / _total : null,
                    ),
                    const SizedBox(height: 12),
                    ExcludeSemantics(
                      child: Text(
                        'Followed $_done of $_total'
                        '${_skipped > 0 ? " ($_skipped skipped)" : ""}',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: _pickAndImport,
                icon: const Icon(Icons.upload_file),
                label: const Text('Choose OPML file'),
              ),
              if (_done > 0) ...[
                const SizedBox(height: 16),
                Text(
                  'Import complete: $_followed followed'
                  '${_skipped > 0 ? ", $_skipped already following" : ""}.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                if (widget.fromOnboarding) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_followed > 0),
                    child: const Text('Done'),
                  ),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Drains [sharedOpmlFilesProvider], importing each shared/opened OPML
  /// file in turn. Runs on entry regardless of how this screen was reached.
  Future<void> _processSharedQueue() async {
    final queue = ref.read(sharedOpmlFilesProvider.notifier);
    var path = queue.takeNext();
    if (path == null || !mounted) return;

    final total = ref.read(sharedOpmlFilesProvider).length + 1;
    var index = 1;

    while (path != null && mounted) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        total > 1
            ? 'Opened from share. Importing file $index of $total.'
            : 'Opened from share. Importing OPML file.',
        TextDirection.ltr,
      );
      await Future<void>.delayed(_shareAnnouncementDelay);
      if (!mounted) return;

      await _importFromPath(path);
      path = queue.takeNext();
      index++;
    }
  }

  Future<void> _pickAndImport() async {
    const typeGroup = XTypeGroup(
      label: 'OPML',
      extensions: ['opml', 'xml'],
      uniformTypeIdentifiers: ['public.xml', 'public.text'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    await _importFromPath(file.path);
  }

  Future<void> _importFromPath(String path) async {
    const maxBytes = 5 * 1024 * 1024; // 5 MB — a valid OPML is well under 1 MB
    int fileSize;
    try {
      fileSize = await File(path).length();
    } on FileSystemException {
      if (mounted) {
        setState(() => _error = 'Could not read file.');
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Error: Could not read file.',
          TextDirection.ltr,
        );
      }
      return;
    }
    if (fileSize > maxBytes) {
      if (mounted) {
        setState(() => _error = 'File is too large to import (max 5 MB).');
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Error: File is too large to import (max 5 MB).',
          TextDirection.ltr,
        );
      }
      return;
    }

    String content;
    try {
      content = await File(path).readAsString();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not read file.');
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Error: Could not read file.',
          TextDirection.ltr,
        );
      }
      return;
    }

    final parsed = ref.read(opmlServiceProvider).parse(content);
    if (parsed.feedUrls.isEmpty) {
      if (mounted) {
        setState(() => _error = 'No podcast feeds found in file.');
        SemanticsService.sendAnnouncement(
          View.of(context),
          'No podcast feeds found in file.',
          TextDirection.ltr,
        );
      }
      return;
    }

    setState(() {
      _importing = true;
      _total = parsed.feedUrls.length;
      _done = 0;
      _skipped = 0;
      _followed = 0;
      _error = null;
    });

    final repo = ref.read(podcastRepositoryProvider);
    for (final url in parsed.feedUrls) {
      try {
        await repo.subscribe(url);
        if (mounted) {
          setState(() {
            _done++;
            _followed++;
          });
          SemanticsService.sendAnnouncement(
            View.of(context),
            'Followed $_done of $_total',
            TextDirection.ltr,
          );
        }
      } on PodcastAlreadySubscribedException {
        if (mounted)
          setState(() {
            _done++;
            _skipped++;
          });
      } catch (e) {
        _log.warning('Failed to subscribe to $url: $e');
        if (mounted) setState(() => _done++);
      }
    }

    if (mounted) {
      setState(() => _importing = false);
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Import complete. Followed $_followed podcast${_followed == 1 ? "" : "s"}'
        '${_skipped > 0 ? ", $_skipped already following" : ""}.',
        TextDirection.ltr,
      );
    }
  }
}
