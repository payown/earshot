import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/downloads/presentation/providers/downloads_providers.dart';
import '../../../../features/settings/data/app_settings_repository.dart';
import '../../../../core/providers/core_providers.dart';
import '../../data/podcast_exception.dart';
import '../providers/subscriptions_providers.dart';

class AddPodcastScreen extends ConsumerStatefulWidget {
  const AddPodcastScreen({super.key, this.fromOnboarding = false});

  final bool fromOnboarding;

  @override
  ConsumerState<AddPodcastScreen> createState() => _AddPodcastScreenState();
}

class _AddPodcastScreenState extends ConsumerState<AddPodcastScreen> {
  final _controller = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Podcast'),
        actions: [
          if (widget.fromOnboarding)
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Done'),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              enabled: !_isLoading,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'RSS feed URL',
                hintText: 'https://example.com/feed.rss',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _isLoading ? null : _submit,
              child: _isLoading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Add Podcast'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final url = _controller.text.trim();

    if (url.isEmpty) {
      _setError('Please enter a URL.');
      return;
    }

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      _setError('URL must start with http:// or https://');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final podcast = await ref.read(podcastRepositoryProvider).subscribe(url);
      final count = await AppSettingsRepositoryImpl(
        database: ref.read(appDatabaseProvider),
      ).getAutoDownloadCount();
      if (count > 0) {
        unawaited(
          ref
              .read(downloadManagerProvider)
              .downloadRecentEpisodes(podcast.id, count),
        );
      }
      if (mounted)
        Navigator.of(context).pop(widget.fromOnboarding ? true : null);
    } on PodcastAlreadySubscribedException {
      _setError('You\'re already subscribed to this podcast.');
    } on PodcastNotFoundException {
      _setError(
        'No podcast found at that URL. Check the address and try again.',
      );
    } on PodcastFetchException {
      _setError(
        'Couldn\'t reach that URL. Check your connection and try again.',
      );
    } catch (_) {
      _setError('Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _setError(String message) {
    setState(() => _error = message);
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      TextDirection.ltr,
    );
  }
}
