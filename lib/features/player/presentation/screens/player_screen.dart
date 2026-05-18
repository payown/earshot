import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/spacing.dart';
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

  @override
  Widget build(BuildContext context) {
    final posLabel = _format(position);
    final durLabel = _format(duration);
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return Semantics(
      label: 'Playback position: $posLabel of $durLabel',
      slider: true,
      value: posLabel,
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
