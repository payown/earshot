import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';

import '../../../../core/router/app_router.dart';
import '../../../../features/subscriptions/data/podcast_exception.dart';
import '../../../../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import '../../domain/search_result.dart';
import '../providers/search_providers.dart';

final _log = Logger('SearchScreen');

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

class _ResultList extends StatelessWidget {
  const _ResultList({required this.results});

  final List<PodcastSearchResult> results;

  @override
  Widget build(BuildContext context) {
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

class _ResultTile extends ConsumerWidget {
  const _ResultTile({required this.result});

  final PodcastSearchResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = result.author != null
        ? '${result.title}, by ${result.author}'
        : result.title;

    return Semantics(
      label: label,
      button: true,
      onTap: () => context.push(AppRoutes.searchResult, extra: result),
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Follow'): () =>
            _follow(context, ref),
      },
      child: ExcludeSemantics(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          onTap: () => context.push(AppRoutes.searchResult, extra: result),
          leading: ExcludeSemantics(
            child: _Artwork(url: result.artworkUrl),
          ),
          title: ExcludeSemantics(
            child: Text(
              result.title,
              style: Theme.of(context).textTheme.titleSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          subtitle: result.author != null
              ? ExcludeSemantics(
                  child: Text(
                    result.author!,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              : null,
          trailing: const ExcludeSemantics(
            child: Icon(Icons.chevron_right),
          ),
        ),
      ),
    );
  }

  Future<void> _follow(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(podcastRepositoryProvider).subscribe(result.feedUrl);
      if (context.mounted) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Following ${result.title}',
          TextDirection.ltr,
        );
      }
    } on PodcastAlreadySubscribedException {
      // already following — no-op
    } catch (e) {
      _log.warning('Follow from search list failed for ${result.feedUrl}: $e');
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
