import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../domain/podcast_folder.dart';

class FolderQuickActionItem {
  const FolderQuickActionItem({required this.label, required this.onInvoke});

  final String label;
  final VoidCallback onInvoke;
}

class FolderListTile extends StatelessWidget {
  const FolderListTile({
    required this.folder,
    required this.podcastCount,
    required this.onTap,
    this.quickActions = const [],
    super.key,
  });

  final PodcastFolder folder;
  final int podcastCount;
  final VoidCallback onTap;
  final List<FolderQuickActionItem> quickActions;

  @override
  Widget build(BuildContext context) {
    final countLabel =
        '$podcastCount ${podcastCount == 1 ? 'podcast' : 'podcasts'}';
    final semanticLabel = '${folder.name}, $countLabel';

    final semanticActions = <CustomSemanticsAction, VoidCallback>{
      for (final action in quickActions)
        CustomSemanticsAction(label: action.label): action.onInvoke,
    };

    return Semantics(
      label: semanticLabel,
      button: true,
      customSemanticsActions: semanticActions,
      child: ExcludeSemantics(
        child: ListTile(
          minTileHeight: 56,
          leading: Icon(
            Icons.folder_outlined,
            color: Theme.of(context).colorScheme.primary,
            semanticLabel: '',
          ),
          title: Text(
            folder.name,
            style: Theme.of(context).textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            countLabel,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      ),
    );
  }
}
