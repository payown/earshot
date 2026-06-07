import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/db/enums.dart';
import '../../domain/quick_action_definition.dart';
import '../providers/settings_providers.dart';

class QuickActionConfiguratorScreen extends ConsumerStatefulWidget {
  const QuickActionConfiguratorScreen({
    required this.contentType,
    super.key,
  });

  final QuickActionContentType contentType;

  @override
  ConsumerState<QuickActionConfiguratorScreen> createState() =>
      _QuickActionConfiguratorScreenState();
}

class _QuickActionConfiguratorScreenState
    extends ConsumerState<QuickActionConfiguratorScreen> {
  List<String>? _activeKeys;
  bool _dirty = false;

  bool get _isEpisode => widget.contentType == QuickActionContentType.episode;

  String get _title =>
      _isEpisode ? 'Episode Quick Actions' : 'Podcast Quick Actions';

  List<String> get _allKeys => _isEpisode
      ? EpisodeAction.values.map((a) => a.key).toList()
      : PodcastAction.values.map((a) => a.key).toList();

  List<String> get _inactiveKeys =>
      _allKeys.where((k) => !(_activeKeys ?? []).contains(k)).toList();

  String _labelFor(String key) {
    if (_isEpisode) {
      return EpisodeAction.values.firstWhere((a) => a.key == key).label;
    }
    return PodcastAction.values.firstWhere((a) => a.key == key).label;
  }

  // Called by SliverReorderableList via onReorderItem — index is already adjusted.
  void _onDragReorder(int oldIndex, int newIndex) {
    _moveItem(oldIndex, newIndex);
  }

  // Called by up/down buttons — newIndex is the final target index.
  void _moveItem(int oldIndex, int newIndex) {
    final newKeys = List<String>.from(_activeKeys ?? _allKeys);
    final item = newKeys.removeAt(oldIndex);
    newKeys.insert(newIndex, item);
    setState(() {
      _dirty = true;
      _activeKeys = newKeys;
    });
  }

  void _removeAction(String key) {
    setState(() {
      _dirty = true;
      _activeKeys = List<String>.from(_activeKeys ?? [])..remove(key);
    });
  }

  void _addAction(String key) {
    setState(() {
      _dirty = true;
      _activeKeys = [...(_activeKeys ?? []), key];
    });
  }

  @override
  Widget build(BuildContext context) {
    // Sync from the provider whenever the user hasn't made local edits yet.
    // Using _dirty instead of _initialized so a re-open after save always picks
    // up the freshly written value rather than Riverpod's stale cache.
    final actionsAsync = _isEpisode
        ? ref.watch(episodeActionsProvider)
        : ref.watch(podcastActionsProvider);
    if (!_dirty) {
      actionsAsync.whenData((actions) {
        _activeKeys = actions
            .map((a) => a is EpisodeAction ? a.key : (a as PodcastAction).key)
            .toList();
      });
    }

    final active = _activeKeys ?? _allKeys;
    final inactive = _inactiveKeys;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'The first active action is the default double-tap action. '
                'Use the up/down buttons or drag to reorder. '
                'Tap Remove to hide an action; tap Add to restore it.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Semantics(
                header: true,
                label: 'Active actions',
                child: ExcludeSemantics(
                  child: Text(
                    'Active',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ),
            ),
          ),
          SliverReorderableList(
            itemCount: active.length,
            onReorderItem: _onDragReorder,
            itemBuilder: (context, index) {
              final key = active[index];
              final label = _labelFor(key);
              return _ActiveActionRow(
                key: ValueKey(key),
                label: label,
                index: index,
                total: active.length,
                isFirst: index == 0,
                onMoveUp: index > 0 ? () => _moveItem(index, index - 1) : null,
                onMoveDown: index < active.length - 1
                    ? () => _moveItem(index, index + 1)
                    : null,
                onRemove: () => _removeAction(key),
              );
            },
          ),
          if (inactive.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Semantics(
                  header: true,
                  label: 'Available actions',
                  child: ExcludeSemantics(
                    child: Text(
                      'Available',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ),
              ),
            ),
            SliverList.builder(
              itemCount: inactive.length,
              itemBuilder: (context, index) {
                final key = inactive[index];
                final label = _labelFor(key);
                return _InactiveActionRow(
                  key: ValueKey('inactive_$key'),
                  label: label,
                  onAdd: () => _addAction(key),
                );
              },
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final keys = _activeKeys ?? _allKeys;
    final repo = ref.read(quickActionRepositoryProvider);
    if (_isEpisode) {
      final actions = keys
          .map((k) => EpisodeAction.values.firstWhere((a) => a.key == k))
          .toList();
      await repo.saveEpisodeActions(actions);
    } else {
      final actions = keys
          .map((k) => PodcastAction.values.firstWhere((a) => a.key == k))
          .toList();
      await repo.savePodcastActions(actions);
    }
    if (mounted) Navigator.of(context).pop();
  }
}

class _ActiveActionRow extends StatelessWidget {
  const _ActiveActionRow({
    required this.label,
    required this.index,
    required this.total,
    required this.isFirst,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
    super.key,
  });

  final String label;
  final int index;
  final int total;
  final bool isFirst;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final position = 'Position ${index + 1} of $total';
    final defaultSuffix = isFirst ? ', default action' : '';

    return Semantics(
      label: '$label$defaultSuffix, $position',
      button: true,
      customSemanticsActions: {
        if (onMoveUp != null)
          const CustomSemanticsAction(label: 'Move up'): onMoveUp!,
        if (onMoveDown != null)
          const CustomSemanticsAction(label: 'Move down'): onMoveDown!,
        const CustomSemanticsAction(label: 'Remove'): onRemove,
      },
      child: ExcludeSemantics(
        child: ListTile(
          title: ExcludeSemantics(
            child: Row(
              children: [
                Text(label, style: Theme.of(context).textTheme.bodyLarge),
                if (isFirst) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Default',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          trailing: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: onMoveUp,
                  tooltip: 'Move up',
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward),
                  onPressed: onMoveDown,
                  tooltip: 'Move down',
                ),
                IconButton(
                  icon: Icon(
                    Icons.remove_circle_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: onRemove,
                  tooltip: 'Remove',
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: const Icon(Icons.drag_handle),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InactiveActionRow extends StatelessWidget {
  const _InactiveActionRow({
    required this.label,
    required this.onAdd,
    super.key,
  });

  final String label;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label, not active',
      button: true,
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Add'): onAdd,
      },
      child: ExcludeSemantics(
        child: ListTile(
          title: ExcludeSemantics(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          trailing: ExcludeSemantics(
            child: IconButton(
              icon: Icon(
                Icons.add_circle_outline,
                color: Theme.of(context).colorScheme.primary,
              ),
              onPressed: onAdd,
              tooltip: 'Add',
            ),
          ),
        ),
      ),
    );
  }
}
