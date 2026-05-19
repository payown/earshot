import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/spacing.dart';
import '../../data/audio_handler.dart';
import '../../domain/sleep_timer.dart';
import '../providers/player_providers.dart';

class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(mediaItemProvider).asData?.value;
    final playbackState = ref.watch(playbackStateProvider).asData?.value;
    final position = ref.watch(positionProvider).asData?.value ?? Duration.zero;

    if (mediaItem == null) {
      return const Scaffold(
        body: Center(child: Text('Nothing playing')),
      );
    }

    final duration = mediaItem.duration ?? Duration.zero;
    final isPlaying = playbackState?.playing ?? false;
    final isBuffering =
        playbackState?.processingState == AudioProcessingState.buffering;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Now Playing'),
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          tooltip: 'Close player',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _Artwork(artUri: mediaItem.artUri)),
              const SizedBox(height: Spacing.lg),
              Semantics(
                header: true,
                child: Text(
                  mediaItem.title,
                  style: Theme.of(context).textTheme.titleLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (mediaItem.album != null) ...[
                const SizedBox(height: 4),
                Text(
                  mediaItem.album!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: Spacing.md),
              _ProgressBar(
                position: position,
                duration: duration,
                onSeek: (p) => ref.read(audioHandlerProvider).seek(p),
              ),
              const SizedBox(height: Spacing.md),
              _PlaybackControls(
                isPlaying: isPlaying,
                isBuffering: isBuffering,
                onRewind: () => ref.read(audioHandlerProvider).rewind(),
                onPlayPause: () => isPlaying
                    ? ref.read(audioHandlerProvider).pause()
                    : ref.read(audioHandlerProvider).play(),
                onFastForward: () =>
                    ref.read(audioHandlerProvider).fastForward(),
              ),
              const SizedBox(height: Spacing.md),
              _SpeedSelector(
                speed: playbackState?.speed ?? 1.0,
                onSpeedChanged: (speed) =>
                    ref.read(audioHandlerProvider).setSpeed(speed),
              ),
              const SizedBox(height: Spacing.md),
              _SleepTimerControls(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.artUri});

  final Uri? artUri;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (artUri == null) {
      return Container(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.podcasts,
          size: 80,
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        artUri.toString(),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.podcasts,
            size: 80,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  // 30-second step matches the skip buttons, so the gesture feels consistent.
  static const _kStep = Duration(seconds: 30);

  @override
  Widget build(BuildContext context) {
    final posLabel = _format(position);
    final durLabel = _format(duration);
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    final increased = _clamp(position + _kStep);
    final decreased = _clamp(position - _kStep);

    return Semantics(
      label: 'Playback position: $posLabel of $durLabel',
      slider: true,
      value: posLabel,
      increasedValue: _format(increased),
      decreasedValue: _format(decreased),
      onIncrease: () => onSeek(increased),
      onDecrease: () => onSeek(decreased),
      child: ExcludeSemantics(
        child: Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: progress.clamp(0.0, 1.0),
                onChanged: (value) {
                  final ms = (value * duration.inMilliseconds).round();
                  onSeek(Duration(milliseconds: ms));
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(posLabel, style: Theme.of(context).textTheme.bodySmall),
                  Text(durLabel, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Duration _clamp(Duration d) {
    if (d.isNegative) return Duration.zero;
    if (duration.inMilliseconds > 0 && d > duration) return duration;
    return d;
  }

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.isPlaying,
    required this.isBuffering,
    required this.onRewind,
    required this.onPlayPause,
    required this.onFastForward,
  });

  final bool isPlaying;
  final bool isBuffering;
  final VoidCallback onRewind;
  final VoidCallback onPlayPause;
  final VoidCallback onFastForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Semantics(
          button: true,
          label: 'Skip back 15 seconds',
          child: ExcludeSemantics(
            child: IconButton(
              icon: const Icon(Icons.replay_30),
              iconSize: 40,
              tooltip: 'Skip back 15 seconds',
              onPressed: onRewind,
            ),
          ),
        ),
        Semantics(
          button: true,
          label: isPlaying ? 'Pause' : 'Play',
          child: ExcludeSemantics(
            child: SizedBox.square(
              dimension: 72,
              child: isBuffering
                  ? const CircularProgressIndicator()
                  : IconButton(
                      icon: Icon(
                        isPlaying ? Icons.pause_circle : Icons.play_circle,
                      ),
                      iconSize: 64,
                      tooltip: isPlaying ? 'Pause' : 'Play',
                      onPressed: onPlayPause,
                    ),
            ),
          ),
        ),
        Semantics(
          button: true,
          label: 'Skip forward 30 seconds',
          child: ExcludeSemantics(
            child: IconButton(
              icon: const Icon(Icons.forward_30),
              iconSize: 40,
              tooltip: 'Skip forward 30 seconds',
              onPressed: onFastForward,
            ),
          ),
        ),
      ],
    );
  }
}

class _SpeedSelector extends StatelessWidget {
  const _SpeedSelector({
    required this.speed,
    required this.onSpeedChanged,
  });

  final double speed;
  final ValueChanged<double> onSpeedChanged;

  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Playback speed: ${_label(speed)}',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _speeds
              .map(
                (s) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(_label(s)),
                    selected: speed == s,
                    onSelected: (_) => onSpeedChanged(s),
                    tooltip: 'Set speed to ${_label(s)}',
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  String _label(double s) => s == s.roundToDouble() ? '${s.toInt()}x' : '${s}x';
}

class _SleepTimerControls extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timerState =
        ref.watch(sleepTimerStateProvider).asData?.value ??
        const SleepTimerState.inactive();
    final handler = ref.read(audioHandlerProvider);

    if (timerState.isActive) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Semantics(
            label: timerState.announcementLabel,
            child: ExcludeSemantics(
              child: Text(
                timerState.endOfEpisode
                    ? 'Sleep: end of episode'
                    : 'Sleep: ${_formatRemaining(timerState.remaining)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            label: 'Extend sleep timer by 5 minutes',
            child: TextButton(
              onPressed: () {
                handler.sleepTimer.extend();
                SemanticsService.sendAnnouncement(
                  View.of(context),
                  'Sleep timer extended by 5 minutes',
                  TextDirection.ltr,
                );
              },
              child: const Text('+5 min'),
            ),
          ),
          Semantics(
            button: true,
            label: 'Cancel sleep timer',
            child: IconButton(
              icon: const Icon(Icons.cancel_outlined),
              iconSize: 20,
              tooltip: 'Cancel sleep timer',
              onPressed: handler.sleepTimer.cancel,
            ),
          ),
        ],
      );
    }

    return Semantics(
      button: true,
      label: 'Set sleep timer',
      child: TextButton.icon(
        icon: const Icon(Icons.bedtime_outlined, size: 18),
        label: const Text('Sleep timer'),
        onPressed: () => _showPicker(context, handler),
      ),
    );
  }

  Future<void> _showPicker(
    BuildContext context,
    EarshotAudioHandler handler,
  ) async {
    final preset = await showModalBottomSheet<SleepTimerPreset>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Sleep timer',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ...SleepTimerPreset.values.map(
              (p) => ListTile(
                title: Text(p.label),
                onTap: () => Navigator.of(context).pop(p),
              ),
            ),
          ],
        ),
      ),
    );

    if (preset != null) {
      handler.sleepTimer.set(preset);
      if (context.mounted) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Sleep timer set for ${preset.label}',
          TextDirection.ltr,
        );
      }
    }
  }

  String _formatRemaining(Duration? d) {
    if (d == null) return '';
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
