import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/subscriptions/data/podcast_exception.dart';
import '../../../../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import '../../domain/search_result.dart';
import '../providers/search_providers.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(podcastSearchProvider(_query));

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Search podcasts…',
            border: InputBorder.none,
            suffixIcon: _query.isNotEmpty
                ? Semantics(
                    button: true,
                    label: 'Clear search',
                    child: IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _query = '');
                      },
                    ),
                  )
                : null,
          ),
          onChanged: (v) => setState(() => _query = v.trim()),
          textInputAction: TextInputAction.search,
        ),
      ),
      body: _query.isEmpty
          ? const _EmptySearch()
          : results.when(
              data: (list) => list.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No podcasts found for "$_query".',
                          style: Theme.of(context).textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : _ResultList(results: list),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Search error: $e')),
            ),
    );
  }
}

class _EmptySearch extends StatelessWidget {
  const _EmptySearch();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              semanticLabel: '',
            ),
            const SizedBox(height: 16),
            Text(
              'Search Apple Podcasts',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Type a podcast name or topic to discover shows.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultList extends ConsumerWidget {
  const _ResultList({required this.results});

  final List<PodcastSearchResult> results;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      label: '${results.length} results',
      child: ListView.separated(
        itemCount: results.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) => _ResultTile(result: results[index]),
      ),
    );
  }
}

class _ResultTile extends ConsumerStatefulWidget {
  const _ResultTile({required this.result});

  final PodcastSearchResult result;

  @override
  ConsumerState<_ResultTile> createState() => _ResultTileState();
}

class _ResultTileState extends ConsumerState<_ResultTile> {
  bool _subscribing = false;
  bool _subscribed = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final label = _subscribed
        ? '${widget.result.title}, subscribed'
        : widget.result.author != null
        ? '${widget.result.title}, by ${widget.result.author}'
        : widget.result.title;

    return Semantics(
      label: label,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: ExcludeSemantics(
          child: _Artwork(url: widget.result.artworkUrl),
        ),
        title: ExcludeSemantics(
          child: Text(
            widget.result.title,
            style: Theme.of(context).textTheme.titleSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        subtitle: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.result.author != null)
                Text(
                  widget.result.author!,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
            ],
          ),
        ),
        trailing: ExcludeSemantics(
          child: _subscribed
              ? Icon(
                  Icons.check_circle,
                  color: Theme.of(context).colorScheme.primary,
                )
              : Semantics(
                  button: true,
                  label: 'Subscribe to ${widget.result.title}',
                  child: FilledButton.tonal(
                    onPressed: _subscribing ? null : _subscribe,
                    child: _subscribing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Subscribe'),
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _subscribe() async {
    setState(() {
      _subscribing = true;
      _error = null;
    });
    try {
      await ref
          .read(podcastRepositoryProvider)
          .subscribe(widget.result.feedUrl);
      if (mounted) {
        setState(() => _subscribed = true);
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Subscribed to ${widget.result.title}',
          TextDirection.ltr,
        );
      }
    } on PodcastAlreadySubscribedException {
      if (mounted) setState(() => _subscribed = true);
    } on PodcastFetchException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong.');
    } finally {
      if (mounted) setState(() => _subscribing = false);
    }
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (url == null) return _placeholder(colorScheme);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url!,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(colorScheme),
      ),
    );
  }

  Widget _placeholder(ColorScheme colorScheme) => Container(
    width: 56,
    height: 56,
    decoration: BoxDecoration(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Icon(Icons.podcasts, size: 28, color: colorScheme.onSurfaceVariant),
  );
}
