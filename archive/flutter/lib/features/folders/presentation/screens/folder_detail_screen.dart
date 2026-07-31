import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/router/app_router.dart';
import '../../../player/presentation/providers/player_providers.dart';
import '../../../subscriptions/presentation/providers/subscriptions_providers.dart';
import '../../../subscriptions/presentation/widgets/podcast_list_tile.dart';
import '../providers/folders_providers.dart';
import '../widgets/folder_podcast_picker_sheet.dart';
import '../../../../features/search/presentation/providers/search_providers.dart';

final _log = Logger('FolderDetailScreen');

class FolderDetailScreen extends ConsumerWidget {
  const FolderDetailScreen({required this.folderId, super.key});

  final int folderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folder = ref.watch(folderProvider(folderId));
    final podcasts = ref.watch(podcastsInFolderProvider(folderId));

    return Scaffold(
      body: folder.when(
        data: (f) {
          if (f == null) {
            return const Center(child: Text('Folder not found.'));
          }
          return CustomScrollView(
            slivers: [
              SliverAppBar(
                title: Text(f.name),
                floating: true,
                actions: [
                  IconButton(
                    icon: const Icon(Icons.playlist_play),
                    tooltip: 'Play all unplayed episodes',
                    onPressed: () => _playAll(context, ref),
                  ),
                  PopupMenuButton<_FolderAction>(
                    tooltip: 'Folder options',
                    onSelected: (action) =>
                        _handleAction(context, ref, action, f.name),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: _FolderAction.exportOpml,
                        child: Text('Export OPML'),
                      ),
                      const PopupMenuItem(
                        value: _FolderAction.rename,
                        child: Text('Rename folder'),
                      ),
                      const PopupMenuItem(
                        value: _FolderAction.setExpiry,
                        child: Text('Set queue expiration'),
                      ),
                      const PopupMenuItem(
                        value: _FolderAction.delete,
                        child: Text('Delete folder'),
                      ),
                    ],
                  ),
                ],
              ),
              podcasts.when(
                data: (items) => items.isEmpty
                    ? const SliverFillRemaining(
                        child: Center(
                          child: Text('No podcasts in this folder yet.'),
                        ),
                      )
                    : SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (ctx, index) => PodcastListTile(
                            podcast: items[index],
                            onTap: () => context.push(
                              AppRoutes.podcastDetail(items[index].id),
                            ),
                            quickActions: [
                              PodcastQuickActionItem(
                                label: 'Remove from folder',
                                onInvoke: () => ref
                                    .read(folderRepositoryProvider)
                                    .removePodcastFromFolder(
                                      folderId,
                                      items[index].id,
                                    ),
                              ),
                            ],
                          ),
                          childCount: items.length,
                        ),
                      ),
                loading: () => const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => SliverFillRemaining(
                  child: Center(child: Text('Error: $e')),
                ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add podcasts to folder',
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          barrierLabel: 'Dismiss folder picker',
          builder: (_) => FolderPodcastPickerSheet(
            mode: AddPodcastsToFolder(folderId),
          ),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _playAll(BuildContext context, WidgetRef ref) async {
    final episodes = await ref
        .read(folderRepositoryProvider)
        .getLatestUnplayedPerPodcast(folderId);

    if (episodes.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No unplayed episodes in this folder.')),
        );
      }
      return;
    }

    final queueRepo = ref.read(queueRepositoryProvider);
    for (final ep in episodes) {
      await queueRepo.addToQueue(ep.id);
    }

    _log.info(
      'Added ${episodes.length} episodes from folder $folderId to queue',
    );

    final first = episodes.first;
    final firstPodcast = ref.read(podcastProvider(first.podcastId)).value;
    final resumePos =
        first.positionSeconds > 0 &&
            first.durationSeconds != null &&
            first.positionSeconds < (first.durationSeconds! * 0.95).round()
        ? first.positionSeconds
        : 0;
    await ref
        .read(audioHandlerProvider)
        .playEpisode(
          MediaItem(
            id: first.audioUrl,
            title: firstPodcast?.title ?? first.title,
            artist: first.title,
            album: firstPodcast?.title,
            artUri: first.artworkUrl != null
                ? Uri.tryParse(first.artworkUrl!)
                : null,
            duration: first.durationSeconds != null
                ? Duration(seconds: first.durationSeconds!)
                : null,
            extras: {
              'episodeId': first.id,
              'podcastId': first.podcastId,
              if (firstPodcast?.speedOverride != null)
                'speedOverride': firstPodcast!.speedOverride!,
              if (firstPodcast?.trimSilenceOverride != null)
                'trimSilenceOverride': firstPodcast!.trimSilenceOverride!,
            },
          ),
          resumePositionSeconds: resumePos,
        );

    if (context.mounted) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Playing ${episodes.length} episode${episodes.length == 1 ? '' : 's'} from folder',
        TextDirection.ltr,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Playing ${episodes.length} episode${episodes.length == 1 ? '' : 's'} from folder',
          ),
        ),
      );
    }
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    _FolderAction action,
    String folderName,
  ) async {
    switch (action) {
      case _FolderAction.exportOpml:
        await _exportOpml(context, ref, folderName);
      case _FolderAction.rename:
        await _renameFolder(context, ref, folderName);
      case _FolderAction.setExpiry:
        await _setExpiry(context, ref);
      case _FolderAction.delete:
        await _deleteFolder(context, ref, folderName);
    }
  }

  Future<void> _exportOpml(
    BuildContext context,
    WidgetRef ref,
    String folderName,
  ) async {
    final subs = await ref
        .read(folderRepositoryProvider)
        .getFolderSubscriptions(folderId);

    if (subs.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No podcasts in this folder to export.'),
          ),
        );
      }
      return;
    }

    final xml = ref.read(opmlServiceProvider).generate(subs);
    final dir = await getTemporaryDirectory();
    final safeName = folderName.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
    final file = File('${dir.path}/earshot-$safeName.opml');
    await file.writeAsString(xml);

    if (context.mounted) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/x-opml')],
          subject: '$folderName — Earshot Subscriptions',
        ),
      );
    }
  }

  Future<void> _renameFolder(
    BuildContext context,
    WidgetRef ref,
    String currentName,
  ) async {
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename Folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Folder name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (newName != null && newName.isNotEmpty) {
      await ref.read(folderRepositoryProvider).renameFolder(folderId, newName);
    }
  }

  Future<void> _setExpiry(BuildContext context, WidgetRef ref) async {
    final folder = ref.read(folderProvider(folderId)).asData?.value;
    final current = folder?.queueAgeLimitDays;

    final controller = TextEditingController(
      text: current != null ? '$current' : '',
    );
    final result = await showDialog<int?>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Queue Expiration'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Episodes older than this many days will be skipped when adding the folder to queue. Leave empty to disable.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Days',
                suffixText: 'days',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(-1),
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              Navigator.of(context).pop(v);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (result == null) return;
    await ref
        .read(folderRepositoryProvider)
        .setFolderQueueAgeLimit(
          folderId,
          result == -1 ? null : result,
        );
  }

  Future<void> _deleteFolder(
    BuildContext context,
    WidgetRef ref,
    String folderName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Folder?'),
        content: Text(
          'Delete "$folderName"? Your podcasts will not be affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(folderRepositoryProvider).deleteFolder(folderId);
      if (context.mounted) {
        context.pop();
      }
    }
  }
}

enum _FolderAction { exportOpml, rename, setExpiry, delete }
