import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';

import 'package:flutter_html/flutter_html.dart';
import 'package:share_plus/share_plus.dart';
import 'package:earshot/core/utils/url_launcher.dart';

import '../../../../core/presentation/widgets/episode_actions_sheet.dart';
import '../../../../core/presentation/widgets/show_notes_dialog.dart';
import '../../../../data/rss/parsed_feed.dart';
import '../../../player/presentation/providers/player_providers.dart';
import '../../../player/presentation/widgets/now_playing_bar.dart';
import '../../../subscriptions/data/podcast_exception.dart';
import '../../../subscriptions/domain/podcast.dart';
import '../../../subscriptions/presentation/providers/subscriptions_providers.dart';
import '../../domain/search_result.dart';
import '../providers/search_preview_providers.dart';

final _log = Logger('SearchResultDetailScreen');

class SearchResultDetailScreen extends ConsumerStatefulWidget {
  const SearchResultDetailScreen({
    required this.result,
    this.fromOnboarding = false,
    super.key,
  });

  final PodcastSearchResult result;
  final bool fromOnboarding;

  @override
  ConsumerState<SearchResultDetailScreen> createState() =>
      _SearchResultDetailScreenState();
}

class _SearchResultDetailScreenState
    extends ConsumerState<SearchResultDetailScreen> {
  bool _following = false;
  bool _unfollowing = false;
  String? _error;
  final FocusNode _followButtonFocusNode = FocusNode();

  PodcastSearchResult get result => widget.result;

  @override
  void dispose() {
    _followButtonFocusNode.dispose();
    super.dispose();
  }

  Future<void> _follow() async {
    setState(() {
      _following = true;
      _error = null;
    });
    try {
      await ref.read(podcastRepositoryProvider).subscribe(result.feedUrl);
      if (mounted) {
        setState(() => _following = false);
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Following ${result.title}',
          TextDirection.ltr,
        );
      }
    } on PodcastAlreadySubscribedException {
      if (mounted) setState(() => _following = false);
    } catch (e) {
      _log.warning('Failed to follow ${result.feedUrl}: $e');
      if (mounted) {
        setState(() {
          _following = false;
          _error = 'Could not follow. Try again.';
        });
      }
    }
  }

  Future<void> _unfollow(Podcast existing) async {
    setState(() => _unfollowing = true);
    try {
      await ref.read(podcastRepositoryProvider).unsubscribe(existing.id);
      if (!mounted) return;
      setState(() => _unfollowing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unfollowed ${result.title}'),
          duration: const Duration(seconds: 3),
        ),
      );
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Unfollowed ${result.title}. Follow button is now available.',
        TextDirection.ltr,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _followButtonFocusNode.requestFocus();
      });
    } catch (e) {
      _log.warning('Failed to unfollow ${result.feedUrl}: $e');
      if (mounted) {
        setState(() => _unfollowing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not unfollow. Try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Podcast> subs =
        ref.watch(subscriptionsProvider).asData?.value ?? [];
    final existing = subs
        .where((Podcast p) => p.rssUrl == result.feedUrl)
        .firstOrNull;
    final isSubscribed = existing != null;

    final preview = ref.watch(podcastPreviewProvider(result.feedUrl));
    final previewPod = preview.asData?.value;

    // Prefer DB record when subscribed, then RSS preview, then search result.
    final subscribedPodcast = isSubscribed
        ? ref.watch(podcastProvider(existing.id)).value
        : null;
    final description =
        subscribedPodcast?.description ??
        previewPod?.description ??
        result.description;
    final fallbackAuthor = result.author ?? previewPod?.author;

    final isLoading = _following || _unfollowing;

    return Scaffold(
      bottomNavigationBar: const NowPlayingBar(),
      appBar: AppBar(
        title: Text(result.title),
        actions: [
          Focus(
            focusNode: _followButtonFocusNode,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Semantics(
                button: true,
                label: isSubscribed
                    ? 'Unfollow ${result.title}'
                    : 'Follow ${result.title}',
                child: ExcludeSemantics(
                  child: isLoading
                      ? const SizedBox(
                          width: 72,
                          child: Center(
                            child: SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      : FilledButton.tonal(
                          onPressed: isSubscribed
                              ? () => _unfollow(existing)
                              : _follow,
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                          ),
                          child: Text(isSubscribed ? 'Unfollow' : 'Follow'),
                        ),
                ),
              ),
            ),
          ),
          if (widget.fromOnboarding)
            TextButton(
              onPressed: () => context.pop(true),
              child: const Text('Done'),
            ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _PodcastHeader(
              result: result,
              fallbackAuthor: fallbackAuthor,
            ),
          ),
          if (description != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Html(
                  data: description,
                  onLinkTap: (url, _, __) async {
                    if (url == null) return;
                    await safeLaunchUrl(url);
                  },
                ),
              ),
            ),
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  _error!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Semantics(
                header: true,
                label: 'Episodes',
                child: ExcludeSemantics(
                  child: Text(
                    'Episodes',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
          ),
          preview.when(
            loading: () => const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) => const SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Could not load episodes.'),
                ),
              ),
            ),
            data: (pod) => pod.episodes.isEmpty
                ? const SliverFillRemaining(
                    child: Center(child: Text('No episodes available.')),
                  )
                : SliverList.builder(
                    itemCount: pod.episodes.length,
                    itemBuilder: (context, i) => _PreviewEpisodeTile(
                      episode: pod.episodes[i],
                      podcastTitle: result.title,
                      podcastArtworkUrl: result.artworkUrl,
                      speedOverride: subscribedPodcast?.speedOverride,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PodcastHeader extends StatelessWidget {
  const _PodcastHeader({required this.result, this.fallbackAuthor});

  final PodcastSearchResult result;
  final String? fallbackAuthor;

  @override
  Widget build(BuildContext context) {
    final author = result.author ?? fallbackAuthor;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: _Artwork(url: result.artworkUrl)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Text(
                    result.title,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (author != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    author,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
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
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url!,
        width: 80,
        height: 80,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(colorScheme),
      ),
    );
  }

  Widget _placeholder(ColorScheme colorScheme) => Container(
    width: 80,
    height: 80,
    decoration: BoxDecoration(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(Icons.podcasts, size: 36, color: colorScheme.onSurfaceVariant),
  );
}

class _PreviewEpisodeTile extends ConsumerWidget {
  const _PreviewEpisodeTile({
    required this.episode,
    this.podcastTitle,
    this.podcastArtworkUrl,
    this.speedOverride,
  });

  final ParsedEpisode episode;
  final String? podcastTitle;
  final String? podcastArtworkUrl;
  final double? speedOverride;

  void _play(BuildContext context, WidgetRef ref) {
    final artworkUrl = episode.artworkUrl ?? podcastArtworkUrl;
    unawaited(
      ref
          .read(audioHandlerProvider)
          .playEpisode(
            MediaItem(
              id: episode.audioUrl,
              title: podcastTitle ?? episode.title,
              artist: episode.title,
              album: podcastTitle,
              artUri: artworkUrl != null ? Uri.tryParse(artworkUrl) : null,
              duration: episode.durationSeconds != null
                  ? Duration(seconds: episode.durationSeconds!)
                  : null,
              extras: {
                if (speedOverride != null) 'speedOverride': speedOverride!,
              },
            ),
          ),
    );
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Playing ${episode.title}',
      TextDirection.ltr,
    );
  }

  void _share() {
    // A search result isn't a persisted Earshot episode, so there's no
    // earshot:// deep link to share; share the media URL itself so a recipient
    // can still listen.
    unawaited(
      SharePlus.instance.share(
        ShareParams(text: episode.audioUrl, subject: episode.title),
      ),
    );
  }

  /// The actions valid for a not-yet-subscribed preview episode. Queue,
  /// download, mark-played and bookmark all require a persisted episode, so
  /// they're intentionally omitted here (see #326) until the user subscribes.
  List<EpisodeQuickActionItem> _actions(BuildContext context, WidgetRef ref) {
    return [
      EpisodeQuickActionItem(
        label: 'Play now',
        onInvoke: () => _play(context, ref),
      ),
      EpisodeQuickActionItem(
        label: 'Open show notes',
        onInvoke: () => showEpisodeShowNotesDialog(
          context,
          title: episode.title,
          descriptionHtml: episode.description,
        ),
      ),
      EpisodeQuickActionItem(label: 'Share', onInvoke: _share),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dateStr = episode.pubDate != null
        ? _formatDate(episode.pubDate!)
        : null;
    final durationStr = episode.durationSeconds != null
        ? _formatDuration(episode.durationSeconds!)
        : null;
    final parts = [
      if (dateStr != null) dateStr,
      if (durationStr != null) durationStr,
    ];
    final semanticLabel = parts.isEmpty
        ? episode.title
        : '${episode.title}, ${parts.join(', ')}';

    final actions = _actions(context, ref);
    // The first action (Play now) is the default double-tap, matching every
    // other episode list in the app.
    final semanticActions = <CustomSemanticsAction, VoidCallback>{
      for (final action in actions)
        CustomSemanticsAction(label: action.label): action.onInvoke,
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Semantics(
            container: true,
            button: true,
            label: semanticLabel,
            onTap: actions.first.onInvoke,
            customSemanticsActions: semanticActions,
            child: ExcludeSemantics(
              child: ListTile(
                onTap: actions.first.onInvoke,
                contentPadding: const EdgeInsets.only(left: 16, right: 4),
                title: Text(
                  episode.title,
                  style: Theme.of(context).textTheme.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: parts.isNotEmpty
                    ? Text(
                        parts.join(' · '),
                        style: Theme.of(context).textTheme.bodySmall,
                      )
                    : null,
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.more_vert),
          tooltip: 'More actions',
          onPressed: () => showEpisodeActionsSheet(
            context,
            episodeTitle: episode.title,
            actions: actions,
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '$seconds sec';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    return rem > 0 ? '$hours hr $rem min' : '$hours hr';
  }
}
