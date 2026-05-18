import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../../../features/subscriptions/data/podcast_exception.dart';
import '../../../../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import '../providers/search_providers.dart';

final _log = Logger('OpmlImport');

class OpmlImportScreen extends ConsumerStatefulWidget {
  const OpmlImportScreen({super.key});

  @override
  ConsumerState<OpmlImportScreen> createState() => _OpmlImportScreenState();
}

class _OpmlImportScreenState extends ConsumerState<OpmlImportScreen> {
  bool _importing = false;
  int _total = 0;
  int _done = 0;
  int _skipped = 0;
  String? _error;

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
                        'Subscribed $_done of $_total'
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
                  'Import complete: $_done subscribed'
                  '${_skipped > 0 ? ", $_skipped already subscribed" : ""}.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
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

  Future<void> _pickAndImport() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['opml', 'xml'],
    );

    if (result == null || result.files.isEmpty) return;

    final path = result.files.first.path;
    if (path == null) return;

    String content;
    try {
      content = await File(path).readAsString();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read file.');
      return;
    }

    final parsed = ref.read(opmlServiceProvider).parse(content);
    if (parsed.feedUrls.isEmpty) {
      if (mounted) setState(() => _error = 'No podcast feeds found in file.');
      return;
    }

    setState(() {
      _importing = true;
      _total = parsed.feedUrls.length;
      _done = 0;
      _skipped = 0;
      _error = null;
    });

    final repo = ref.read(podcastRepositoryProvider);
    for (final url in parsed.feedUrls) {
      try {
        await repo.subscribe(url);
        if (mounted) {
          setState(() => _done++);
          SemanticsService.sendAnnouncement(
            View.of(context),
            'Subscribed $_done of $_total',
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

    if (mounted) setState(() => _importing = false);
  }
}
