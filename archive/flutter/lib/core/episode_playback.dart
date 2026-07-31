import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/enums.dart';
import '../features/downloads/presentation/providers/downloads_providers.dart';
import '../features/player/domain/resume_position.dart';
import '../features/player/presentation/providers/player_providers.dart';
import '../features/settings/presentation/providers/settings_providers.dart';
import '../features/subscriptions/domain/episode.dart';
import '../features/subscriptions/presentation/providers/subscriptions_providers.dart';

/// Canonical "Play now" for an episode, shared by every screen.
///
/// Behavior on every surface (Inbox, Queue, Library, Downloads):
/// - If [episode] is already loaded in the player, resumes in place instead
///   of reloading: if paused, calls [EarshotAudioHandler.play] and announces
///   "Playing {title}"; if already playing, announces "Already playing" so
///   screen reader users get confirmation the activation was registered. This
///   avoids reseeking to the last DB-saved position, which lags the live
///   position by up to [PositionTracker]'s save interval and would otherwise
///   replay a few seconds of audio on every re-tap.
/// - Otherwise, builds the MediaItem with episode artwork (podcast artwork
///   fallback), per-podcast speed/trim overrides, and the local download path
///   when the episode is downloaded, so downloaded episodes never stream.
///   Resumes from the saved position via [clampedResumePosition].
/// - Adds the episode to the queue (no-op when already queued); entering the
///   queue is what removes it from the Inbox.
/// - Triggers queue auto-download when that setting is on.
/// - Announces "Playing {title}" unless [announce] is false (callers that
///   send their own announcement, like Play group, pass false).
///
/// Episodes are never marked played here; completion handling owns that.
void playEpisodeNow({
  required BuildContext context,
  required WidgetRef ref,
  required Episode episode,
  bool announce = true,
}) {
  final handler = ref.read(audioHandlerProvider);

  final currentEpisodeId =
      ref.read(mediaItemProvider).value?.extras?['episodeId'] as int?;
  if (currentEpisodeId == episode.id) {
    final isPlaying = ref.read(playbackStateProvider).value?.playing ?? false;
    if (!isPlaying) {
      unawaited(handler.play());
      if (announce && context.mounted) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Playing ${episode.title}',
          TextDirection.ltr,
        );
      }
    } else if (announce && context.mounted) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Already playing',
        TextDirection.ltr,
      );
    }
    return;
  }

  final podcast = ref.read(podcastProvider(episode.podcastId)).value;
  final artworkUrl = episode.artworkUrl ?? podcast?.artworkUrl;

  unawaited(
    handler.playEpisode(
      MediaItem(
        id: episode.audioUrl,
        title: podcast?.title ?? episode.title,
        artist: episode.title,
        album: podcast?.title,
        artUri: artworkUrl != null ? Uri.tryParse(artworkUrl) : null,
        duration: episode.durationSeconds != null
            ? Duration(seconds: episode.durationSeconds!)
            : null,
        extras: {
          'episodeId': episode.id,
          'podcastId': episode.podcastId,
          if (podcast?.speedOverride != null)
            'speedOverride': podcast!.speedOverride!,
          if (podcast?.trimSilenceOverride != null)
            'trimSilenceOverride': podcast!.trimSilenceOverride!,
          if (episode.downloadPath != null)
            'downloadPath': episode.downloadPath!,
        },
      ),
      resumePositionSeconds: clampedResumePosition(
        positionSeconds: episode.positionSeconds,
        durationSeconds: episode.durationSeconds,
      ),
    ),
  );

  // Place the episode so playback flows correctly under the play-in-place /
  // advance-downward model: a brand-new episode (from Inbox/Library/Downloads)
  // goes to the front so it plays now and then continues into the queue, while
  // an already-queued episode is left where it sits (order preserved).
  unawaited(ref.read(queueRepositoryProvider).addToFrontIfAbsent(episode.id));
  triggerQueueDownloadIfEnabled(episode, ref, context);

  if (announce && context.mounted) {
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Playing ${episode.title}',
      TextDirection.ltr,
    );
  }
}

/// Downloads the episode if auto-download-queue is on and the episode is not
/// already downloaded or actively downloading.
void triggerQueueDownloadIfEnabled(
  Episode episode,
  WidgetRef ref,
  BuildContext context,
) {
  final autoDownload = ref.read(autoDownloadQueueProvider).value ?? false;
  if (!autoDownload) return;
  final status = episode.downloadStatus;
  if (status == DownloadStatus.downloaded ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.pending) {
    return;
  }
  unawaited(
    ref
        .read(downloadManagerProvider)
        .downloadEpisode(
          episode.id,
          onComplete: (message) {
            if (context.mounted) {
              SemanticsService.sendAnnouncement(
                View.of(context),
                message == 'Download complete'
                    ? '${episode.title} downloaded'
                    : 'Download failed for ${episode.title}',
                TextDirection.ltr,
              );
            }
          },
        ),
  );
}
