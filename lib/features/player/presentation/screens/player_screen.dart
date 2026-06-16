import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:earshot/core/utils/url_launcher.dart';

import '../../../../core/constants/spacing.dart';
import '../../../../core/constants/urls.dart';
import '../../../../features/bookmarks/presentation/providers/bookmarks_providers.dart';
import '../../../../features/settings/presentation/providers/settings_providers.dart';
import '../../../../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import '../../domain/sleep_timer.dart';
import '../providers/chapter_providers.dart';
import '../providers/player_providers.dart';
import '../widgets/airplay_button.dart';
import '../widgets/chapter_controls.dart';
import '../widgets/speed_selector.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  // Speed saved before a hold-to-fast-forward gesture (GestureDetector path).
  double? _speedBeforeHold;
  // Whether fast-forward is active via the VoiceOver rotor action path.
  bool _voFastForwardActive = false;
  // Tracks which chapter index was most recently auto-skipped to avoid loops.
  int? _lastAutoSkipFromChapterIndex;
  // Set to true before any speed change that is part of fast-forward so the
  // playbackState listener skips the announcement (those paths announce their
  // own state explicitly).
  bool _suppressSpeedAnnouncement = false;

  @override
  void dispose() {
    if (_speedBeforeHold != null) {
      ref.read(audioHandlerProvider).setSpeed(_speedBeforeHold!);
    }
    super.dispose();
  }

  // ── GestureDetector paths (sighted users) ────────────────────────────────

  void _onHoldStart() {
    _speedBeforeHold =
        ref.read(playbackStateProvider).asData?.value.speed ?? 1.0;
    _suppressSpeedAnnouncement = true;
    ref.read(audioHandlerProvider).setSpeed(4.0);
  }

  void _onHoldEnd() {
    _suppressSpeedAnnouncement = true;
    ref.read(audioHandlerProvider).setSpeed(_speedBeforeHold ?? 1.0);
    _speedBeforeHold = null;
  }

  void _onVerticalDrag(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v < 0) {
      _skipForward();
    } else if (v > 0) {
      _skipBack();
    }
  }

  // ── Rotor action paths (VoiceOver / TalkBack users) ──────────────────────

  void _startVoFastForward() {
    _speedBeforeHold =
        ref.read(playbackStateProvider).asData?.value.speed ?? 1.0;
    _suppressSpeedAnnouncement = true;
    ref.read(audioHandlerProvider).setSpeed(4.0);
    setState(() => _voFastForwardActive = true);
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Fast forward at 4 times speed',
      TextDirection.ltr,
    );
  }

  void _stopVoFastForward() {
    _suppressSpeedAnnouncement = true;
    ref.read(audioHandlerProvider).setSpeed(_speedBeforeHold ?? 1.0);
    _speedBeforeHold = null;
    setState(() => _voFastForwardActive = false);
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Fast forward stopped',
      TextDirection.ltr,
    );
  }

  // ── Shared ────────────────────────────────────────────────────────────────

  void _skipForward() {
    final secs = ref.read(skipForwardSecondsProvider).value ?? 30;
    ref.read(audioHandlerProvider).fastForward();
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Skip forward $secs seconds',
      TextDirection.ltr,
    );
  }

  void _skipBack() {
    final secs = ref.read(skipBackSecondsProvider).value ?? 15;
    ref.read(audioHandlerProvider).rewind();
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Skip back $secs seconds',
      TextDirection.ltr,
    );
  }

  Future<void> _resetToGlobal({
    required BuildContext context,
    required int podcastId,
  }) async {
    final repo = ref.read(podcastRepositoryProvider);
    final handler = ref.read(audioHandlerProvider);
    await repo.disableCustomSettings(podcastId);
    final globalSpeed = await ref.read(globalSpeedProvider.future);
    final globalTrimSilence = await ref.read(skipSilenceProvider.future);
    _suppressSpeedAnnouncement = true;
    await handler.setSpeed(globalSpeed);
    await handler.setSkipSilenceEnabled(globalTrimSilence);
    if (context.mounted) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Reset to global speed',
        TextDirection.ltr,
      );
    }
  }

  /// Marks the current episode as played and advances to the next queued
  /// episode (or stops when the queue is empty), so the user can move on
  /// without playing to the end. Reuses the handler's completion flow.
  Future<void> _markAsPlayed(BuildContext context) async {
    final hasEpisode =
        ref.read(mediaItemProvider).asData?.value?.extras?['episodeId'] is int;
    if (!hasEpisode) return;
    await ref.read(audioHandlerProvider).markCurrentEpisodePlayed();
    if (context.mounted) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Marked as played',
        TextDirection.ltr,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaItem = ref.watch(mediaItemProvider).asData?.value;
    final podcastId = mediaItem?.extras?['podcastId'] as int?;
    final podcast = ref.watch(optionalPodcastProvider(podcastId)).asData?.value;
    final hasCustomSettings = podcast?.hasPlaybackOverride ?? false;
    final playbackState = ref.watch(playbackStateProvider).asData?.value;
    final position = ref.watch(positionProvider).asData?.value ?? Duration.zero;
    final directTouchEnabled =
        ref.watch(directTouchEnabledProvider).value ?? false;
    final skipFwdSecs = ref.watch(skipForwardSecondsProvider).value ?? 30;
    final skipBackSecs = ref.watch(skipBackSecondsProvider).value ?? 15;
    final description = ref
        .watch(currentEpisodeDescriptionProvider)
        .asData
        ?.value;

    // Stop rotor fast-forward if the setting is turned off mid-session.
    ref.listen<AsyncValue<bool>>(directTouchEnabledProvider, (_, next) {
      if (next.value == false && _voFastForwardActive) {
        _stopVoFastForward();
      }
    });

    // Announce speed changes to VoiceOver/TalkBack (covers both manual changes
    // and per-podcast override auto-applied on episode load).
    // Fast-forward paths set _suppressSpeedAnnouncement before calling setSpeed
    // so their own explicit announcements aren't duplicated here.
    ref.listen<AsyncValue<PlaybackState>>(playbackStateProvider, (prev, next) {
      if (_suppressSpeedAnnouncement) {
        _suppressSpeedAnnouncement = false;
        return;
      }
      final prevSpeed = prev?.asData?.value.speed;
      final nextSpeed = next.asData?.value.speed;
      if (prevSpeed != null && nextSpeed != null && nextSpeed != prevSpeed) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Speed set to ${SpeedSelector.formatSpeed(nextSpeed)}',
          TextDirection.ltr,
        );
      }
    });

    // Auto-skip chapters the user has marked as skipped.
    ref.listen<AsyncValue<Duration>>(positionProvider, (_, next) {
      final position = next.asData?.value;
      if (position == null) return;
      final chapters = ref.read(chaptersProvider).asData?.value;
      if (chapters == null || chapters.isEmpty) return;
      final currentIndex = ref.read(currentChapterIndexProvider);
      if (currentIndex == null) return;
      final episodeId =
          ref
              .read(mediaItemProvider)
              .asData
              ?.value
              ?.extras?['episodeId']
              ?.toString() ??
          '';
      final skipped = ref.read(skippedChaptersProvider)[episodeId] ?? {};
      if (!skipped.contains(currentIndex)) {
        _lastAutoSkipFromChapterIndex = null;
        return;
      }
      if (_lastAutoSkipFromChapterIndex == currentIndex) return;
      for (var i = currentIndex + 1; i < chapters.length; i++) {
        if (!skipped.contains(i)) {
          _lastAutoSkipFromChapterIndex = currentIndex;
          ref
              .read(audioHandlerProvider)
              .seek(
                Duration(
                  milliseconds: (chapters[i].startTime * 1000).round(),
                ),
              );
          SemanticsService.sendAnnouncement(
            View.of(context),
            'Skipping chapter: ${chapters[currentIndex].title}',
            TextDirection.ltr,
          );
          return;
        }
      }
      _lastAutoSkipFromChapterIndex = currentIndex;
    });

    if (mediaItem == null) {
      return const Scaffold(
        body: Center(child: Text('Nothing playing')),
      );
    }

    final duration = mediaItem.duration ?? Duration.zero;
    final isPlaying = playbackState?.playing ?? false;
    final isBuffering =
        playbackState?.processingState == AudioProcessingState.buffering;

    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Now Playing'),
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          tooltip: 'Close player',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          const AirPlayButton(),
          PopupMenuButton<void>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Episode actions',
            itemBuilder: (_) => [
              PopupMenuItem<void>(
                // Use the screen's context, not the menu builder's: the menu
                // route is closing when onTap fires, so the builder context can
                // already be unmounted and the announcement would be dropped.
                onTap: () => _markAsPlayed(context),
                child: Semantics(
                  button: true,
                  label: 'Mark as played',
                  child: const ExcludeSemantics(child: Text('Mark as played')),
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 1.0,
                child: Semantics(
                  // Label change on fast-forward state forces VoiceOver to
                  // refresh customSemanticsActions (workaround for Flutter
                  // issue #149613 where rotor actions don't update otherwise).
                  label: _voFastForwardActive
                      ? 'Artwork. Fast forward active.'
                      : 'Artwork',
                  // The Artwork node is this screen's actions host, so it always
                  // carries Mark as played (exposed even when Direct Touch is
                  // off). The skip / fast-forward actions are added on top only
                  // when Direct Touch is enabled. Mark as played lives here
                  // rather than on the title because a header node is not a
                  // reliable place for VoiceOver rotor actions.
                  customSemanticsActions: {
                    const CustomSemanticsAction(label: 'Mark as played'): () =>
                        _markAsPlayed(context),
                    if (directTouchEnabled) ...{
                      CustomSemanticsAction(
                        label: 'Skip forward $skipFwdSecs seconds',
                      ): _skipForward,
                      CustomSemanticsAction(
                        label: 'Skip back $skipBackSecs seconds',
                      ): _skipBack,
                      if (!_voFastForwardActive)
                        const CustomSemanticsAction(
                          label: 'Start Fast Forward',
                        ): _startVoFastForward,
                      if (_voFastForwardActive)
                        const CustomSemanticsAction(
                          label: 'Stop Fast Forward',
                        ): _stopVoFastForward,
                    },
                  },
                  child: GestureDetector(
                    onLongPress: directTouchEnabled ? _onHoldStart : null,
                    onLongPressEnd: directTouchEnabled
                        ? (_) => _onHoldEnd()
                        : null,
                    onVerticalDragEnd: directTouchEnabled
                        ? _onVerticalDrag
                        : null,
                    child: _Artwork(artUri: mediaItem.artUri),
                  ),
                ),
              ),
              const SizedBox(height: Spacing.lg),
              Semantics(
                header: true,
                label: mediaItem.title,
                child: ExcludeSemantics(
                  child: Text(
                    mediaItem.title,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
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
              const ChapterControls(),
              const SizedBox(height: Spacing.md),
              _PlaybackControls(
                isPlaying: isPlaying,
                isBuffering: isBuffering,
                skipForwardSecs: skipFwdSecs,
                skipBackSecs: skipBackSecs,
                onRewind: () => ref.read(audioHandlerProvider).rewind(),
                onPlayPause: () => isPlaying
                    ? ref.read(audioHandlerProvider).pause()
                    : ref.read(audioHandlerProvider).play(),
                onFastForward: () =>
                    ref.read(audioHandlerProvider).fastForward(),
              ),
              const SizedBox(height: Spacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        ExcludeSemantics(
                          child: Text('Speed', style: labelStyle),
                        ),
                        const SizedBox(height: Spacing.xs),
                        SpeedSelector(
                          speed: playbackState?.speed ?? 1.0,
                          onSpeedChanged: (speed) async {
                            await ref
                                .read(audioHandlerProvider)
                                .setSpeed(speed);
                            if (podcastId != null) {
                              await ref
                                  .read(podcastRepositoryProvider)
                                  .updateSpeedOverride(podcastId, speed);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        ExcludeSemantics(
                          child: Text('Sleep timer', style: labelStyle),
                        ),
                        const SizedBox(height: Spacing.xs),
                        _SleepTimerControls(),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              _AudioExtrasRow(podcastId: podcastId),
              if (hasCustomSettings && podcastId != null) ...[
                const SizedBox(height: Spacing.xs),
                Semantics(
                  button: true,
                  label: 'Reset to global speed',
                  onTap: () => _resetToGlobal(
                    context: context,
                    podcastId: podcastId,
                  ),
                  child: ExcludeSemantics(
                    child: TextButton(
                      onPressed: () => _resetToGlobal(
                        context: context,
                        podcastId: podcastId,
                      ),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(88, 48),
                      ),
                      child: const Text('Reset to global speed'),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: Spacing.sm),
              if (mediaItem.extras?['episodeId'] is int)
                _BookmarksSection(
                  episodeId: mediaItem.extras!['episodeId'] as int,
                ),
              _ShowNotesSection(description: description),
              const SizedBox(height: Spacing.md),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookmarksSection extends ConsumerStatefulWidget {
  const _BookmarksSection({required this.episodeId});

  final int episodeId;

  @override
  ConsumerState<_BookmarksSection> createState() => _BookmarksSectionState();
}

class _BookmarksSectionState extends ConsumerState<_BookmarksSection> {
  bool _expanded = false;

  String _formatPosition(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  Future<void> _seekTo(int positionSeconds) async {
    await ref
        .read(audioHandlerProvider)
        .seek(Duration(seconds: positionSeconds));
    if (mounted) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Jumped to ${_formatPosition(positionSeconds)}',
        TextDirection.ltr,
      );
    }
  }

  Future<void> _delete(int bookmarkId, int positionSeconds) async {
    await ref.read(bookmarkRepositoryProvider).deleteBookmark(bookmarkId);
    if (mounted) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Bookmark at ${_formatPosition(positionSeconds)} deleted',
        TextDirection.ltr,
      );
    }
  }

  Future<void> _share(int positionSeconds) async {
    final url = '$kEpisodeBaseUrl/${widget.episodeId}?t=$positionSeconds';
    await SharePlus.instance.share(ShareParams(text: url));
  }

  @override
  Widget build(BuildContext context) {
    final bookmarks = ref
        .watch(bookmarksForEpisodeProvider(widget.episodeId))
        .asData
        ?.value;

    if (bookmarks == null || bookmarks.isEmpty) return const SizedBox.shrink();

    final disableAnimations = MediaQuery.of(context).disableAnimations;
    final theme = Theme.of(context);
    final count = bookmarks.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ExcludeSemantics(child: Divider(height: 1)),
        Semantics(
          button: true,
          expanded: _expanded,
          label: _expanded
              ? 'Bookmarks, $count ${count == 1 ? 'item' : 'items'}, expanded'
              : 'Bookmarks, $count ${count == 1 ? 'item' : 'items'}, collapsed',
          onTap: () => setState(() => _expanded = !_expanded),
          child: ExcludeSemantics(
            child: GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                child: Row(
                  children: [
                    Text(
                      'Bookmarks ($count)',
                      style: theme.textTheme.titleSmall,
                    ),
                    const Spacer(),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: disableAnimations
                          ? Duration.zero
                          : const Duration(milliseconds: 200),
                      child: const Icon(Icons.expand_more),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          child: _expanded
              ? Column(
                  children: [
                    for (final bookmark in bookmarks)
                      _BookmarkRow(
                        positionLabel: _formatPosition(
                          bookmark.positionSeconds,
                        ),
                        note: bookmark.note,
                        onSeek: () => _seekTo(bookmark.positionSeconds),
                        onDelete: () =>
                            _delete(bookmark.id, bookmark.positionSeconds),
                        onShare: () => _share(bookmark.positionSeconds),
                      ),
                    const SizedBox(height: Spacing.xs),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _BookmarkRow extends StatelessWidget {
  const _BookmarkRow({
    required this.positionLabel,
    required this.note,
    required this.onSeek,
    required this.onDelete,
    required this.onShare,
  });

  final String positionLabel;
  final String note;
  final VoidCallback onSeek;
  final VoidCallback onDelete;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trimmedNote = note.trim();
    final semanticLabel = trimmedNote.isNotEmpty
        ? 'Bookmark at $positionLabel: $trimmedNote'
        : 'Bookmark at $positionLabel';

    return Semantics(
      button: true,
      label: semanticLabel,
      hint: 'Jump to this position',
      onTap: onSeek,
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Delete bookmark'): onDelete,
        const CustomSemanticsAction(label: 'Share bookmark'): onShare,
      },
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onSeek,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
            child: Row(
              children: [
                Text(
                  positionLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (trimmedNote.isNotEmpty) ...[
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      trimmedNote,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ] else
                  const Spacer(),
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  iconSize: 20,
                  tooltip: 'Share bookmark',
                  onPressed: onShare,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  padding: EdgeInsets.zero,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  iconSize: 20,
                  tooltip: 'Delete bookmark',
                  onPressed: onDelete,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ShowNotesSection extends StatefulWidget {
  const _ShowNotesSection({required this.description});

  final String? description;

  @override
  State<_ShowNotesSection> createState() => _ShowNotesSectionState();
}

class _ShowNotesSectionState extends State<_ShowNotesSection> {
  bool _expanded = false;
  final FocusNode _contentFocusNode = FocusNode(
    debugLabel: 'show-notes-content',
  );

  @override
  void dispose() {
    _contentFocusNode.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (!mounted) return;
    SemanticsService.sendAnnouncement(
      View.of(context),
      _expanded ? 'Show notes expanded' : 'Show notes collapsed',
      TextDirection.ltr,
    );
    if (_expanded) {
      // AnimatedSize revealing a new subtree can cause VoiceOver to lose its
      // accessibility focus and fall back to the first element on screen.
      // Explicitly move focus to the top of the newly-revealed content.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _contentFocusNode.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Semantics(
          button: true,
          expanded: _expanded,
          label: _expanded ? 'Show notes, expanded' : 'Show notes, collapsed',
          onTap: _toggle,
          child: ExcludeSemantics(
            child: InkWell(
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                child: Row(
                  children: [
                    Text('Show notes', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: disableAnimations
                          ? Duration.zero
                          : const Duration(milliseconds: 200),
                      child: const Icon(Icons.expand_more),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Focus(
                        focusNode: _contentFocusNode,
                        // Reachable via requestFocus() to direct VoiceOver
                        // focus here on expand, but not a Tab/arrow-key stop
                        // for hardware-keyboard users since it wraps inert
                        // content.
                        skipTraversal: true,
                        child: widget.description != null
                            ? Html(
                                data: widget.description!,
                                onLinkTap: (url, _, __) async {
                                  if (url == null) return;
                                  await safeLaunchUrl(url);
                                },
                              )
                            : Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: Spacing.sm,
                                ),
                                child: Text(
                                  'No show notes available.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(height: Spacing.sm),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Semantics(
                          button: true,
                          label: 'Collapse show notes',
                          onTap: _toggle,
                          child: ExcludeSemantics(
                            child: TextButton(
                              onPressed: _toggle,
                              child: const Text('Collapse show notes'),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
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

    final remaining = duration > position ? duration - position : Duration.zero;
    final semanticLabel = duration.inSeconds > 0
        ? '${_formatNatural(remaining)} remaining, ${_formatNatural(duration)} total'
        : 'Playback position: $posLabel';

    return Semantics(
      label: semanticLabel,
      slider: true,
      value: posLabel,
      increasedValue: _format(increased),
      decreasedValue: _format(decreased),
      onIncrease: () => onSeek(increased),
      onDecrease: () => onSeek(decreased),
      excludeSemantics: true,
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

  String _formatNatural(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0 && m > 0) {
      return '$h ${h == 1 ? 'hour' : 'hours'} $m ${m == 1 ? 'minute' : 'minutes'}';
    }
    if (h > 0) return '$h ${h == 1 ? 'hour' : 'hours'}';
    if (m > 0) return '$m ${m == 1 ? 'minute' : 'minutes'}';
    return '$s ${s == 1 ? 'second' : 'seconds'}';
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.isPlaying,
    required this.isBuffering,
    required this.skipForwardSecs,
    required this.skipBackSecs,
    required this.onRewind,
    required this.onPlayPause,
    required this.onFastForward,
  });

  final bool isPlaying;
  final bool isBuffering;
  final int skipForwardSecs;
  final int skipBackSecs;
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
          label: 'Skip back $skipBackSecs seconds',
          onTap: onRewind,
          child: ExcludeSemantics(
            child: IconButton(
              icon: const Icon(Icons.replay_30),
              iconSize: 40,
              tooltip: 'Skip back $skipBackSecs seconds',
              onPressed: onRewind,
            ),
          ),
        ),
        Semantics(
          key: const ValueKey('player_play_pause'),
          button: true,
          label: isPlaying ? 'Pause' : 'Play',
          onTap: onPlayPause,
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
          label: 'Skip forward $skipForwardSecs seconds',
          onTap: onFastForward,
          child: ExcludeSemantics(
            child: IconButton(
              icon: const Icon(Icons.forward_30),
              iconSize: 40,
              tooltip: 'Skip forward $skipForwardSecs seconds',
              onPressed: onFastForward,
            ),
          ),
        ),
      ],
    );
  }
}

class _SleepTimerControls extends ConsumerWidget {
  // Timed options first (ascending), end of episode last. null = Off.
  static final _options = <SleepTimerPreset?>[
    null,
    SleepTimerPreset.fiveMinutes,
    SleepTimerPreset.tenMinutes,
    SleepTimerPreset.fifteenMinutes,
    SleepTimerPreset.thirtyMinutes,
    SleepTimerPreset.fortyFiveMinutes,
    SleepTimerPreset.sixtyMinutes,
    SleepTimerPreset.endOfEpisode,
  ];

  static String _label(SleepTimerPreset? p) => p == null ? 'Off' : p.label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timerState =
        ref.watch(sleepTimerStateProvider).asData?.value ??
        const SleepTimerState.inactive();
    final handler = ref.read(audioHandlerProvider);

    final currentPreset = timerState.preset;
    final idx = _options.indexOf(currentPreset);
    final prev = idx > 0 ? _options[idx - 1] : null;
    final next = idx < _options.length - 1 ? _options[idx + 1] : null;

    void applyPreset(SleepTimerPreset? p) {
      if (p == null) {
        handler.sleepTimer.cancel();
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Sleep timer cancelled',
          TextDirection.ltr,
        );
      } else {
        handler.sleepTimer.set(p);
        SemanticsService.sendAnnouncement(
          View.of(context),
          timerState.isActive
              ? 'Sleep timer set for ${p.label}'
              : 'Sleep timer set for ${p.label}. Extend by 5 minutes button now available.',
          TextDirection.ltr,
        );
      }
    }

    final canExtend = timerState.isActive && !timerState.endOfEpisode;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: 'Sleep timer',
          slider: true,
          value: timerState.isActive && !timerState.endOfEpisode
              ? '${_label(currentPreset)}, ${_formatRemaining(timerState.remaining)} remaining'
              : _label(currentPreset),
          decreasedValue: idx > 0 ? _label(prev) : null,
          increasedValue: next != null ? _label(next) : null,
          onDecrease: idx > 0 ? () => applyPreset(prev) : null,
          onIncrease: next != null ? () => applyPreset(next) : null,
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                iconSize: 28,
                style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: idx > 0 ? () => applyPreset(prev) : null,
              ),
              SizedBox(
                width: 80,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _label(currentPreset),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (timerState.isActive && !timerState.endOfEpisode)
                      Text(
                        _formatRemaining(timerState.remaining),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                iconSize: 28,
                style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: next != null ? () => applyPreset(next) : null,
              ),
            ],
          ),
        ),
        if (canExtend)
          Semantics(
            button: true,
            label: 'Extend sleep timer by 5 minutes',
            onTap: () {
              handler.sleepTimer.extend();
              SemanticsService.sendAnnouncement(
                View.of(context),
                'Sleep timer extended by 5 minutes',
                TextDirection.ltr,
              );
            },
            child: ExcludeSemantics(
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
          ),
      ],
    );
  }

  String _formatRemaining(Duration? d) {
    if (d == null) return '';
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _AudioExtrasRow extends ConsumerWidget {
  const _AudioExtrasRow({required this.podcastId});

  final int? podcastId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final podcast = ref.watch(optionalPodcastProvider(podcastId)).asData?.value;
    final globalTrimSilence =
        ref.watch(skipSilenceProvider).asData?.value ?? false;
    final trimSilence = podcast?.trimSilenceOverride ?? globalTrimSilence;
    final voiceEnhance = ref.watch(voiceEnhanceProvider).asData?.value ?? false;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ToggleChip(
          label: 'Trim Silence',
          icon: Icons.graphic_eq,
          enabled: trimSilence,
          onToggle: (v) async {
            if (podcastId != null) {
              await ref
                  .read(podcastRepositoryProvider)
                  .updateTrimSilenceOverride(podcastId!, v);
            } else {
              await ref.read(skipSilenceProvider.notifier).set(v);
            }
            await ref.read(audioHandlerProvider).setSkipSilenceEnabled(v);
          },
        ),
        // Voice Boost requires AVAudioEngine EQ insertion, which just_audio's
        // iOS backend (AVQueuePlayer) does not support. Hidden on iOS until
        // https://github.com/ryanheise/just_audio/pull/784 lands or a native
        // plugin is built. Android works via AndroidLoudnessEnhancer.
        if (!Platform.isIOS) ...[
          const SizedBox(width: 12),
          _ToggleChip(
            label: 'Voice Boost',
            icon: Icons.spatial_audio,
            enabled: voiceEnhance,
            onToggle: (v) async {
              await ref.read(voiceEnhanceProvider.notifier).set(v);
              await ref.read(audioHandlerProvider).setVoiceEnhance(v);
            },
          ),
        ],
      ],
    );
  }
}

class _ToggleChip extends StatelessWidget {
  const _ToggleChip({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onToggle,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = enabled
        ? colorScheme.secondaryContainer
        : colorScheme.surfaceContainerHighest;
    final contentColor = enabled
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurfaceVariant;

    return Semantics(
      toggled: enabled,
      label: label,
      button: true,
      enabled: true,
      onTap: () => onToggle(!enabled),
      child: ExcludeSemantics(
        child: Material(
          color: backgroundColor,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onToggle(!enabled),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: contentColor),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: contentColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
