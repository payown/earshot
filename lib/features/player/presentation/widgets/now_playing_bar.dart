import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/playback.dart';
import '../../../../core/router/app_router.dart';
import '../providers/player_providers.dart';

class NowPlayingBar extends ConsumerWidget {
  const NowPlayingBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(mediaItemProvider).asData?.value;
    final playbackState = ref.watch(playbackStateProvider).asData?.value;
    final timerState = ref.watch(sleepTimerStateProvider).asData?.value;

    if (mediaItem == null || playbackState == null)
      return const SizedBox.shrink();
    if (playbackState.processingState == AudioProcessingState.idle) {
      return const SizedBox.shrink();
    }

    final isPlaying = playbackState.playing;
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      header: true,
      label: isPlaying ? 'Now Playing' : 'Paused',
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              // Tappable area: artwork + title opens the full player.
              // ExcludeSemantics only covers this section — controls remain
              // individually accessible outside it.
              Expanded(
                child: Semantics(
                  button: true,
                  label:
                      '${isPlaying ? 'Now playing' : 'Paused'}: ${mediaItem.title}',
                  hint: 'Opens full player',
                  onTap: () => _openPlayer(context),
                  child: ExcludeSemantics(
                    child: InkWell(
                      onTap: () => _openPlayer(context),
                      child: Row(
                        children: [
                          _Artwork(artUri: mediaItem.artUri),
                          const SizedBox(width: 12),
                          Expanded(
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
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _ControlButton(
                icon: Icons.replay_30,
                tooltip: 'Skip back ${kSkipBackDuration.inSeconds} seconds',
                onPressed: () => ref.read(audioHandlerProvider).rewind(),
              ),
              _ControlButton(
                icon: isPlaying ? Icons.pause : Icons.play_arrow,
                tooltip: isPlaying ? 'Pause' : 'Play',
                onPressed: () => isPlaying
                    ? ref.read(audioHandlerProvider).pause()
                    : ref.read(audioHandlerProvider).play(),
              ),
              if (timerState?.isActive == true)
                Semantics(
                  button: true,
                  label: 'Extend sleep timer by 5 minutes',
                  child: ExcludeSemantics(
                    child: TextButton(
                      onPressed: () {
                        ref.read(audioHandlerProvider).sleepTimer.extend();
                        SemanticsService.sendAnnouncement(
                          View.of(context),
                          'Sleep timer extended by 5 minutes',
                          TextDirection.ltr,
                        );
                      },
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(48, 48),
                      ),
                      child: const Text('+5 min'),
                    ),
                  ),
                ),
              _ControlButton(
                icon: Icons.forward_30,
                tooltip:
                    'Skip forward ${kSkipForwardDuration.inSeconds} seconds',
                onPressed: () => ref.read(audioHandlerProvider).fastForward(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openPlayer(BuildContext context) {
    context.push(AppRoutes.player);
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
          style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
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
