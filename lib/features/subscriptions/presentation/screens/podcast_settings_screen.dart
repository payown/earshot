import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/spacing.dart';
import '../../../../features/player/presentation/widgets/speed_selector.dart';
import '../../domain/podcast.dart';
import '../providers/subscriptions_providers.dart';

class PodcastSettingsScreen extends ConsumerWidget {
  const PodcastSettingsScreen({required this.podcastId, super.key});

  final int podcastId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final podcastAsync = ref.watch(podcastProvider(podcastId));

    return podcastAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Error: $e')),
      ),
      data: (podcast) {
        if (podcast == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Podcast not found.')),
          );
        }
        return _PodcastSettingsView(podcast: podcast);
      },
    );
  }
}

class _PodcastSettingsView extends ConsumerWidget {
  const _PodcastSettingsView({required this.podcast});

  final Podcast podcast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text('${podcast.title} Settings')),
      body: ListView(
        children: [
          _sectionHeader(context, 'Playback'),
          ListTile(
            title: const Text('Playback speed'),
            subtitle: Text(
              podcast.speedOverride != null
                  ? SpeedSelector.formatSpeed(podcast.speedOverride!)
                  : 'Global',
            ),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => _showSpeedSheet(context, ref, podcast),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String label) {
    return Semantics(
      header: true,
      label: label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md,
            Spacing.md,
            Spacing.md,
            Spacing.xs,
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSpeedSheet(
    BuildContext context,
    WidgetRef ref,
    Podcast podcast,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierLabel: 'Dismiss playback speed settings',
      builder: (sheetContext) => _SpeedSheet(podcast: podcast),
    );
  }
}

class _SpeedSheet extends ConsumerStatefulWidget {
  const _SpeedSheet({required this.podcast});

  final Podcast podcast;

  @override
  ConsumerState<_SpeedSheet> createState() => _SpeedSheetState();
}

class _SpeedSheetState extends ConsumerState<_SpeedSheet> {
  late double? _selectedSpeed;

  @override
  void initState() {
    super.initState();
    _selectedSpeed = widget.podcast.speedOverride;
  }

  @override
  Widget build(BuildContext context) {
    final currentSpeed = _selectedSpeed ?? 1.0;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.md,
          Spacing.lg,
          Spacing.md,
          Spacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              label: 'Playback speed',
              child: ExcludeSemantics(
                child: Text(
                  'Playback speed',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Override the global speed for this podcast only.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Spacing.lg),
            SpeedSelector(
              speed: currentSpeed,
              onSpeedChanged: (s) => setState(() => _selectedSpeed = s),
            ),
            const SizedBox(height: Spacing.lg),
            Semantics(
              button: true,
              label: 'Save speed override',
              child: ExcludeSemantics(
                child: FilledButton(
                  onPressed: () => _save(context),
                  child: const Text('Save'),
                ),
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Semantics(
              button: true,
              label: 'Use global speed',
              child: ExcludeSemantics(
                child: TextButton(
                  onPressed: () => _clearOverride(context),
                  child: const Text('Use global speed'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    await ref
        .read(podcastRepositoryProvider)
        .updateSpeedOverride(widget.podcast.id, _selectedSpeed);
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _clearOverride(BuildContext context) async {
    await ref
        .read(podcastRepositoryProvider)
        .updateSpeedOverride(widget.podcast.id, null);
    if (context.mounted) Navigator.of(context).pop();
  }
}
