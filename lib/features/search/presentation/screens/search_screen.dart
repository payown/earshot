import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';

import '../../../../core/router/app_router.dart';
import '../../../../features/subscriptions/data/podcast_exception.dart';
import '../../../../features/subscriptions/domain/podcast.dart';
import '../../../../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import '../../domain/search_result.dart';
import '../providers/search_providers.dart';

final _log = Logger('SearchScreen');

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.fromOnboarding = false});

  final bool fromOnboarding;

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
                    child: ExcludeSemantics(
                      child: IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                      ),
                    ),
                  )
                : null,
          ),
          onChanged: (v) => setState(() => _query = v.trim()),
          textInputAction: TextInputAction.search,
        ),
        actions: [
          if (widget.fromOnboarding)
            TextButton(
              onPressed: () => context.pop(true),
              child: const Text('Done'),
            ),
        ],
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
                  : _ResultList(
                      results: list,
                      fromOnboarding: widget.fromOnboarding,
                    ),
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

class _ResultList extends StatelessWidget {
  const _ResultList({
    required this.results,
    required this.fromOnboarding,
  });

  final List<PodcastSearchResult> results;
  final bool fromOnboarding;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${results.length} results',
      child: ListView.separated(
        itemCount: results.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) => _ResultTile(
          result: results[index],
          fromOnboarding: fromOnboarding,
        ),
      ),
    );
  }
}

class _ResultTile extends ConsumerStatefulWidget {
  const _ResultTile({required this.result, required this.fromOnboarding});

  final PodcastSearchResult result;
  final bool fromOnboarding;

  @override
  ConsumerState<_ResultTile> createState() => _ResultTileState();
}

class _ResultTileState extends ConsumerState<_ResultTile> {
  // Optimistic local state: flips the action label immediately on tap
  // without waiting for the network + DB round-trip.
  // null = defer to subscriptionsProvider; true/false = local override.
  bool? _optimisticFollowed;

  bool _isSubscribed(List<Podcast> subscriptions) =>
      _optimisticFollowed ??
      subscriptions.any((p) => p.rssUrl == widget.result.feedUrl);

  int? _subscribedId(List<Podcast> subscriptions) => subscriptions
      .where((p) => p.rssUrl == widget.result.feedUrl)
      .firstOrNull
      ?.id;

  Future<void> _openDetail() async {
    final done = await context.push<bool>(
      AppRoutes.searchResult,
      extra: (widget.result, widget.fromOnboarding),
    );
    if (done == true && mounted) context.pop(true);
  }

  Future<void> _follow() async {
    setState(() => _optimisticFollowed = true);
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Following ${widget.result.title}',
      TextDirection.ltr,
    );
    try {
      await ref
          .read(podcastRepositoryProvider)
          .subscribe(widget.result.feedUrl);
    } on PodcastAlreadySubscribedException {
      // already following — optimistic state is correct, keep it
    } catch (e) {
      _log.warning(
        'Follow from search list failed for ${widget.result.feedUrl}: $e',
      );
      setState(() => _optimisticFollowed = null);
      if (mounted) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Could not follow ${widget.result.title}. Try again.',
          TextDirection.ltr,
        );
      }
    }
  }

  Future<void> _unfollow(int podcastId) async {
    setState(() => _optimisticFollowed = false);
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Unfollowed ${widget.result.title}',
      TextDirection.ltr,
    );
    try {
      await ref.read(podcastRepositoryProvider).unsubscribe(podcastId);
    } catch (e) {
      _log.warning(
        'Unfollow from search list failed for ${widget.result.feedUrl}: $e',
      );
      setState(() => _optimisticFollowed = null);
      if (mounted) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Could not unfollow ${widget.result.title}. Try again.',
          TextDirection.ltr,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.result.author != null
        ? '${widget.result.title}, by ${widget.result.author}'
        : widget.result.title;

    final subscriptions = ref.watch(subscriptionsProvider).asData?.value ?? [];
    final isSubscribed = _isSubscribed(subscriptions);
    final subscribedId = _subscribedId(subscriptions);

    return Semantics(
      label: label,
      button: true,
      onTap: _openDetail,
      customSemanticsActions: {
        if (!isSubscribed)
          const CustomSemanticsAction(label: 'Follow'): () {
            _follow();
          },
        if (isSubscribed && subscribedId != null)
          const CustomSemanticsAction(label: 'Unfollow'): () {
            _unfollow(subscribedId);
          },
      },
      child: ExcludeSemantics(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          onTap: _openDetail,
          leading: _Artwork(url: widget.result.artworkUrl),
          title: Text(
            widget.result.title,
            style: Theme.of(context).textTheme.titleSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: widget.result.author != null
              ? Text(
                  widget.result.author!,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
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
