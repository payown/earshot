import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/quick_action_definition.dart';
import '../providers/settings_providers.dart';
import 'settings_screen.dart';

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
  List<String>? _orderedKeys;

  bool get _isEpisode => widget.contentType == QuickActionContentType.episode;

  String get _title =>
      _isEpisode ? 'Episode Quick Actions' : 'Podcast Quick Actions';

  List<String> get _allKeys => _isEpisode
      ? EpisodeAction.values.map((a) => a.key).toList()
      : PodcastAction.values.map((a) => a.key).toList();

  String _labelFor(String key) {
    if (_isEpisode) {
      return EpisodeAction.values.firstWhere((a) => a.key == key).label;
    }
    return PodcastAction.values.firstWhere((a) => a.key == key).label;
  }

  @override
  Widget build(BuildContext context) {
    final stored = _isEpisode
        ? ref.watch(episodeActionsProvider)
        : ref.watch(podcastActionsProvider);

    if (_orderedKeys == null) {
      stored.whenData((actions) {
        _orderedKeys = actions
            .map((a) => a is EpisodeAction ? a.key : (a as PodcastAction).key)
            .toList();
        // Append any actions not yet in the stored list
        for (final key in _allKeys) {
          if (!_orderedKeys!.contains(key)) _orderedKeys!.add(key);
        }
      });
    }

    final keys = _orderedKeys ?? _allKeys;

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
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'The first action is the default double-tap action. '
              'Use the up/down buttons to reorder.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: keys.length,
              onReorderItem: (oldIndex, newIndex) {
                setState(() {
                  final item = keys.removeAt(oldIndex);
                  keys.insert(newIndex, item);
                  _orderedKeys = List.from(keys);
                });
              },
              itemBuilder: (context, index) {
                final key = keys[index];
                final label = _labelFor(key);
                return _ActionRow(
                  key: ValueKey(key),
                  label: label,
                  index: index,
                  total: keys.length,
                  isFirst: index == 0,
                  onMoveUp: index > 0
                      ? () => setState(() {
                          _orderedKeys = List.from(keys)
                            ..insert(index - 1, (keys..removeAt(index)).first);
                        })
                      : null,
                  onMoveDown: index < keys.length - 1
                      ? () => setState(() {
                          final item = keys.removeAt(index);
                          keys.insert(index + 1, item);
                          _orderedKeys = List.from(keys);
                        })
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final keys = _orderedKeys ?? _allKeys;
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
    if (mounted) {
      ref.invalidate(episodeActionsProvider);
      ref.invalidate(podcastActionsProvider);
      Navigator.of(context).pop();
    }
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.label,
    required this.index,
    required this.total,
    required this.isFirst,
    required this.onMoveUp,
    required this.onMoveDown,
    super.key,
  });

  final String label;
  final int index;
  final int total;
  final bool isFirst;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    final position = 'Position ${index + 1} of $total';
    final defaultLabel = isFirst ? ' (default action)' : '';

    return Semantics(
      label: '$label$defaultLabel, $position',
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
              Semantics(
                button: true,
                label: 'Move $label up',
                child: IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: onMoveUp,
                  tooltip: 'Move up',
                ),
              ),
              Semantics(
                button: true,
                label: 'Move $label down',
                child: IconButton(
                  icon: const Icon(Icons.arrow_downward),
                  onPressed: onMoveDown,
                  tooltip: 'Move down',
                ),
              ),
              const Icon(Icons.drag_handle),
            ],
          ),
        ),
      ),
    );
  }
}
