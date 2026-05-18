import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/player_providers.dart';
import '../screens/player_screen.dart';

class NowPlayingBar extends ConsumerWidget {
  const NowPlayingBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(mediaItemProvider).asData?.value;
    final playbackState = ref.watch(playbackStateProvider).asData?.value;

    if (mediaItem == null || playbackState == null)
      return const SizedBox.shrink();
    if (playbackState.processingState == AudioProcessingState.idle) {
      return const SizedBox.shrink();
    }

    final isPlaying = playbackState.playing;
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      label: 'Now playing: ${mediaItem.title}',
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        child: InkWell(
          onTap: () => _openPlayer(context),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  _Artwork(artUri: mediaItem.artUri),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            mediaItem.title,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (mediaItem.album != null)
                            Text(
                              mediaItem.album!,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ),
                  _ControlButton(
                    icon: Icons.replay_30,
                    tooltip: 'Skip back 15 seconds',
                    onPressed: () => ref.read(audioHandlerProvider).rewind(),
                  ),
                  _ControlButton(
                    icon: isPlaying ? Icons.pause : Icons.play_arrow,
                    tooltip: isPlaying ? 'Pause' : 'Play',
                    onPressed: () => isPlaying
                        ? ref.read(audioHandlerProvider).pause()
                        : ref.read(audioHandlerProvider).play(),
                  ),
                  _ControlButton(
                    icon: Icons.forward_30,
                    tooltip: 'Skip forward 30 seconds',
                    onPressed: () =>
                        ref.read(audioHandlerProvider).fastForward(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openPlayer(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const PlayerScreen()),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: ExcludeSemantics(
        child: IconButton(
          icon: Icon(icon),
          tooltip: tooltip,
          onPressed: onPressed,
          iconSize: 28,
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
      return _placeholder(colorScheme);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        artUri.toString(),
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(colorScheme),
      ),
    );
  }

  Widget _placeholder(ColorScheme colorScheme) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Icon(Icons.podcasts, size: 22, color: colorScheme.onSurfaceVariant),
  );
}
