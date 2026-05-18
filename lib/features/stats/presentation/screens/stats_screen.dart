import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/stats_period.dart';
import '../providers/stats_providers.dart';

class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  StatsPeriod _period = StatsPeriod.thisWeek;

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(statsProvider(_period));

    return Scaffold(
      appBar: AppBar(title: const Text('Stats')),
      body: Column(
        children: [
          _PeriodSelector(
            selected: _period,
            onChanged: (p) => setState(() => _period = p),
          ),
          Expanded(
            child: stats.when(
              data: (s) => ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      _period.label,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _StatTile(
                    label: 'Time listened',
                    value: _formatDuration(s.totalSeconds),
                  ),
                  _StatTile(
                    label: 'Time saved by speed',
                    value: _formatDuration(s.timeSavedSeconds),
                  ),
                  _StatTile(
                    label: 'Episodes completed',
                    value: '${s.episodesCompleted}',
                  ),
                  if (s.perPodcast.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Semantics(
                      header: true,
                      child: Text(
                        'By Podcast',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...s.perPodcast.map(
                      (p) => _StatTile(
                        label: p.podcastTitle,
                        value: _formatDuration(p.totalSeconds),
                        subtitle:
                            '${p.episodeCount} episode${p.episodeCount == 1 ? '' : 's'}',
                      ),
                    ),
                  ],
                ],
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(int seconds) {
    if (seconds == 0) return '0 minutes';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0 && m > 0)
      return '$h ${h == 1 ? "hour" : "hours"}, $m ${m == 1 ? "minute" : "minutes"}';
    if (h > 0) return '$h ${h == 1 ? "hour" : "hours"}';
    if (m > 0) return '$m ${m == 1 ? "minute" : "minutes"}';
    return '$s ${s == 1 ? "second" : "seconds"}';
  }
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.selected, required this.onChanged});

  final StatsPeriod selected;
  final ValueChanged<StatsPeriod> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Semantics(
        label: 'Time period: ${selected.label}',
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: StatsPeriod.values
                .map(
                  (p) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(p.label),
                      selected: selected == p,
                      onSelected: (_) => onChanged(p),
                      tooltip: 'Show stats for ${p.label}',
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    this.subtitle,
  });

  final String label;
  final String value;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: subtitle != null ? '$label: $value, $subtitle' : '$label: $value',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            ExcludeSemantics(
              child: Text(
                value,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
