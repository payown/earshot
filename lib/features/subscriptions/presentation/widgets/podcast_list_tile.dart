import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../domain/podcast.dart';

class PodcastQuickActionItem {
  const PodcastQuickActionItem({required this.label, required this.onInvoke});

  final String label;
  final VoidCallback onInvoke;
}

class PodcastListTile extends StatelessWidget {
  const PodcastListTile({
    required this.podcast,
    required this.onTap,
    this.quickActions = const [],
    super.key,
  });

  final Podcast podcast;
  final VoidCallback onTap;
  final List<PodcastQuickActionItem> quickActions;

  @override
  Widget build(BuildContext context) {
    final label = podcast.author != null
        ? '${podcast.title}, by ${podcast.author}'
        : podcast.title;

    final semanticActions = <CustomSemanticsAction, VoidCallback>{
      for (final action in quickActions)
        CustomSemanticsAction(label: action.label): action.onInvoke,
    };

    return Semantics(
      label: label,
      button: true,
      customSemanticsActions: semanticActions,
      child: ExcludeSemantics(
        child: ListTile(
          minTileHeight: 72,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          leading: _Artwork(url: podcast.artworkUrl),
          title: Text(
            podcast.title,
            style: Theme.of(context).textTheme.titleMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: podcast.author != null
              ? Text(
                  podcast.author!,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          onTap: onTap,
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

    if (url == null) {
      return _placeholder(colorScheme);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url!,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(colorScheme),
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : _placeholder(colorScheme),
      ),
    );
  }

  Widget _placeholder(ColorScheme colorScheme) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        Icons.podcasts,
        size: 28,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}
