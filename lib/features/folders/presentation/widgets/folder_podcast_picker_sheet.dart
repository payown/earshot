import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../subscriptions/domain/podcast.dart';
import '../../../subscriptions/presentation/providers/subscriptions_providers.dart';
import '../../domain/podcast_folder.dart';
import '../providers/folders_providers.dart';
import 'create_folder_dialog.dart';

sealed class FolderPickerMode {
  const FolderPickerMode();
}

final class AddPodcastsToFolder extends FolderPickerMode {
  const AddPodcastsToFolder(this.folderId);
  final int folderId;
}

final class ManageFoldersForPodcast extends FolderPickerMode {
  const ManageFoldersForPodcast(this.podcastId);
  final int podcastId;
}

class FolderPodcastPickerSheet extends ConsumerStatefulWidget {
  const FolderPodcastPickerSheet({required this.mode, super.key});

  final FolderPickerMode mode;

  @override
  ConsumerState<FolderPodcastPickerSheet> createState() =>
      _FolderPodcastPickerSheetState();
}

class _FolderPodcastPickerSheetState
    extends ConsumerState<FolderPodcastPickerSheet> {
  Set<int> _selectedIds = {};
  bool _initialized = false;

  @override
  Widget build(BuildContext context) {
    return switch (widget.mode) {
      AddPodcastsToFolder(folderId: final folderId) => _buildAddPodcastsMode(
        context,
        folderId,
      ),
      ManageFoldersForPodcast(podcastId: final podcastId) =>
        _buildManageFoldersMode(context, podcastId),
    };
  }

  // ── Mode: pick podcasts to add to a folder ──────────────────────────────────

  Widget _buildAddPodcastsMode(BuildContext context, int folderId) {
    final allPodcasts = ref.watch(subscriptionsProvider);
    final inFolderIds =
        ref
            .watch(podcastsInFolderProvider(folderId))
            .asData
            ?.value
            .map((p) => p.id)
            .toSet() ??
        {};

    if (!_initialized && allPodcasts.asData != null) {
      _selectedIds = Set.from(inFolderIds);
      _initialized = true;
    }

    return _SheetScaffold(
      title: 'Add Podcasts',
      onDone: () => _applyPodcastChanges(folderId, inFolderIds),
      body: allPodcasts.when(
        data: (podcasts) => _PodcastCheckList(
          podcasts: podcasts,
          selectedIds: _selectedIds,
          onToggle: (id, checked) => setState(
            () => checked ? _selectedIds.add(id) : _selectedIds.remove(id),
          ),
          onCreateFolder: null,
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  Future<void> _applyPodcastChanges(
    int folderId,
    Set<int> previousIds,
  ) async {
    final repo = ref.read(folderRepositoryProvider);
    final added = _selectedIds.difference(previousIds);
    final removed = previousIds.difference(_selectedIds);

    for (final id in added) {
      await repo.addPodcastToFolder(folderId, id);
    }
    for (final id in removed) {
      await repo.removePodcastFromFolder(folderId, id);
    }

    if (mounted) {
      final total = added.length + removed.length;
      if (total > 0) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          '$total podcast${total == 1 ? '' : 's'} updated',
          TextDirection.ltr,
        );
      }
      Navigator.of(context).pop();
    }
  }

  // ── Mode: manage folders for a podcast ─────────────────────────────────────

  Widget _buildManageFoldersMode(BuildContext context, int podcastId) {
    final allFolders = ref.watch(foldersProvider);
    final currentFolderIds =
        ref
            .watch(folderIdsForPodcastProvider(podcastId))
            .asData
            ?.value
            .toSet() ??
        {};

    if (!_initialized && allFolders.asData != null) {
      _selectedIds = Set.from(currentFolderIds);
      _initialized = true;
    }

    return _SheetScaffold(
      title: 'Add to Folder',
      onDone: () => _applyFolderChanges(podcastId, currentFolderIds),
      body: allFolders.when(
        data: (folders) => _FolderCheckList(
          folders: folders,
          selectedIds: _selectedIds,
          onToggle: (id, checked) => setState(
            () => checked ? _selectedIds.add(id) : _selectedIds.remove(id),
          ),
          onCreateFolder: () => _createFolder(podcastId),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  Future<void> _applyFolderChanges(
    int podcastId,
    Set<int> previousIds,
  ) async {
    final repo = ref.read(folderRepositoryProvider);
    await repo.setMemberships(podcastId, _selectedIds.toList());

    if (mounted) {
      final total = _selectedIds.length;
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Podcast added to $total ${total == 1 ? 'folder' : 'folders'}',
        TextDirection.ltr,
      );
      Navigator.of(context).pop();
    }
  }

  Future<void> _createFolder(int podcastId) async {
    final folder = await showDialog<PodcastFolder>(
      context: context,
      builder: (_) => const CreateFolderDialog(),
    );
    if (folder != null) {
      setState(() => _selectedIds.add(folder.id));
    }
  }
}

// ── Private helpers ─────────────────────────────────────────────────────────

class _SheetScaffold extends StatelessWidget {
  const _SheetScaffold({
    required this.title,
    required this.onDone,
    required this.body,
  });

  final String title;
  final VoidCallback onDone;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              FilledButton(
                onPressed: onDone,
                child: const Text('Done'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Flexible(child: body),
      ],
    );
  }
}

class _PodcastCheckList extends StatelessWidget {
  const _PodcastCheckList({
    required this.podcasts,
    required this.selectedIds,
    required this.onToggle,
    required this.onCreateFolder,
  });

  final List<Podcast> podcasts;
  final Set<int> selectedIds;
  final void Function(int id, bool checked) onToggle;
  final VoidCallback? onCreateFolder;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      shrinkWrap: true,
      itemCount: podcasts.length,
      itemBuilder: (context, index) {
        final podcast = podcasts[index];
        final checked = selectedIds.contains(podcast.id);
        return Semantics(
          label: '${podcast.title}, ${checked ? 'in folder' : 'not in folder'}',
          child: ExcludeSemantics(
            child: CheckboxListTile(
              value: checked,
              onChanged: (v) => onToggle(podcast.id, v ?? false),
              title: Text(podcast.title),
              subtitle: podcast.author != null ? Text(podcast.author!) : null,
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ),
        );
      },
    );
  }
}

class _FolderCheckList extends StatelessWidget {
  const _FolderCheckList({
    required this.folders,
    required this.selectedIds,
    required this.onToggle,
    required this.onCreateFolder,
  });

  final List<PodcastFolder> folders;
  final Set<int> selectedIds;
  final void Function(int id, bool checked) onToggle;
  final VoidCallback? onCreateFolder;

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      children: [
        for (final folder in folders) ...[
          Semantics(
            label:
                '${folder.name}, ${selectedIds.contains(folder.id) ? 'selected' : 'not selected'}',
            child: ExcludeSemantics(
              child: CheckboxListTile(
                value: selectedIds.contains(folder.id),
                onChanged: (v) => onToggle(folder.id, v ?? false),
                title: Text(folder.name),
                controlAffinity: ListTileControlAffinity.leading,
                secondary: const Icon(Icons.folder_outlined),
              ),
            ),
          ),
        ],
        if (onCreateFolder != null)
          Semantics(
            button: true,
            label: 'Create new folder',
            child: ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('Create new folder'),
              onTap: onCreateFolder,
            ),
          ),
      ],
    );
  }
}
