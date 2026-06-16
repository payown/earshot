import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';

import '../../../core/constants/playback.dart';
import '../../../data/db/app_database.dart';
import '../../../features/settings/data/app_settings_repository.dart';
import '../domain/sleep_timer.dart';

final _log = Logger('AudioHandler');

/// Returns [AudioSource.file] when the item has a local [downloadPath] in its
/// extras, otherwise falls back to streaming via [AudioSource.uri].
AudioSource resolveAudioSource(MediaItem item) {
  final downloadPath = item.extras?['downloadPath'] as String?;
  if (downloadPath != null) {
    return AudioSource.file(downloadPath);
  }
  return AudioSource.uri(Uri.parse(item.id));
}

/// Returns true when the player should preload the next episode.
/// [position] >= [duration] - [threshold] triggers buffering.
bool shouldPreload(Duration position, Duration duration, Duration threshold) =>
    duration > Duration.zero && position >= duration - threshold;

/// Returns true when an audio interruption end event warrants resuming playback.
///
/// [wasPlaying] must reflect whether the player was actively playing when the
/// interruption began, so a user-initiated pause before an alarm fires does not
/// trigger an unwanted auto-resume when the alarm ends.
@visibleForTesting
bool shouldResumeAfterInterruption(
  AudioInterruptionEvent event, {
  required bool wasPlaying,
}) => !event.begin && event.type == AudioInterruptionType.pause && wasPlaying;

/// A completed event is only genuine when the player reached ready since the
/// last load AND playback was requested since then. Completion-on-load (e.g.
/// restoring at/past the media end after a crash) never satisfies both, so it
/// must not mark the episode played or remove it from the queue.
///
/// [playRequestedSinceLoad] is a sticky flag rather than the player's
/// instantaneous `playing` value so a pause landing at the exact media end
/// can't suppress a genuine completion.
bool shouldHonorCompleted({
  required bool readySinceLoad,
  required bool playRequestedSinceLoad,
}) => readySinceLoad && playRequestedSinceLoad;

/// True when the episode about to be played is the same one that just
/// completed. This happens when `markPlayedAndRemove` silently no-ops (the
/// episode was already removed by a concurrent gapless advance) and the
/// completed episode is still at the head of the queue. In that case we must
/// stop rather than restart it from the beginning.
bool nextEqualsCompleted(int? nextEpisodeId, int? completedEpisodeId) =>
    nextEpisodeId != null && nextEpisodeId == completedEpisodeId;

/// Whether a preloaded next episode has gone stale and must be dropped so it
/// can't play gaplessly. The preload is anchored to the episode that follows
/// the currently-playing one in the live queue; if the queue changed so that
/// the preloaded episode is no longer that next item (it was removed, or a
/// reorder/edit changed what comes next), the preload is stale (#297).
///
/// Returns false (keep the preload) when nothing is preloaded, when the current
/// episode is no longer in the queue (a separate concern), or when the
/// preloaded episode is still the correct next one.
bool preloadedNextIsStale({
  required int? preloadedNextEpisodeId,
  required int? currentEpisodeId,
  required List<int> queueEpisodeIds,
}) {
  if (preloadedNextEpisodeId == null) return false;
  if (currentEpisodeId == null) return false;
  final currentIndex = queueEpisodeIds.indexOf(currentEpisodeId);
  if (currentIndex < 0) return false;
  final intendedNextId = currentIndex + 1 < queueEpisodeIds.length
      ? queueEpisodeIds[currentIndex + 1]
      : null;
  return intendedNextId != preloadedNextEpisodeId;
}

/// How a `ProcessingState.completed` event should be handled.
enum CompletedAction {
  /// Process the completion: mark played, advance or stop.
  honor,

  /// A gapless advance is in flight; this completion belongs to the episode
  /// being advanced past, not the newly-promoted current episode. Ignore it.
  ignoreAdvancing,

  /// Spurious completion with no genuine playback since the last load (e.g.
  /// restoring at/past the media end after a crash). Ignore it.
  ignoreSpurious,
}

/// Decides what to do with a `completed` event. Pure so the gating logic can
/// be unit-tested without the platform player. The advance gate takes priority
/// over the spurious gate: while [isAdvancing] is true the honor flags still
/// reflect the previous (now-finished) episode, so they must not be consulted.
CompletedAction classifyCompleted({
  required bool isAdvancing,
  required bool readySinceLoad,
  required bool playRequestedSinceLoad,
}) {
  if (isAdvancing) return CompletedAction.ignoreAdvancing;
  if (!shouldHonorCompleted(
    readySinceLoad: readySinceLoad,
    playRequestedSinceLoad: playRequestedSinceLoad,
  )) {
    return CompletedAction.ignoreSpurious;
  }
  return CompletedAction.honor;
}

class EarshotAudioHandler extends BaseAudioHandler with SeekHandler {
  EarshotAudioHandler() {
    _loudnessEnhancer = AndroidLoudnessEnhancer();
    _player = AudioPlayer(
      audioPipeline: AudioPipeline(
        androidAudioEffects: [_loudnessEnhancer],
      ),
    );
    _attachPlaybackListener();
    _attachIndexListener();
    _attachProcessingStateListener();

    sleepTimer = SleepTimer(
      onExpired: () {
        pause();
      },
    );

    AudioSession.instance.then((session) {
      if (_disposed) return;
      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          _wasPlayingBeforeInterruption = _player.playing;
          pause();
        } else if (shouldResumeAfterInterruption(
          event,
          wasPlaying: _wasPlayingBeforeInterruption,
        )) {
          // iOS set AVAudioSessionInterruptionOptionShouldResume and we were
          // actually playing when interrupted — safe to resume.
          play();
        }
      });
      _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
        pause();
      });
    });
  }

  late final AndroidLoudnessEnhancer _loudnessEnhancer;
  late final AudioPlayer _player;
  late final SleepTimer sleepTimer;

  AppSettingsRepository? _settings;
  AppDatabase? _db;

  Duration _skipForwardDuration = kSkipForwardDuration;
  Duration _skipBackDuration = kSkipBackDuration;

  // Called by the provider layer once the DB is available so _applyPlaybackSettings
  // can read global speed + trim silence without relying on MediaItem extras.
  void attachSettings(AppSettingsRepository settings) {
    _settings = settings;
  }

  void attachDatabase(AppDatabase db) {
    _db = db;
  }

  void setSkipDurations({required Duration forward, required Duration back}) {
    _skipForwardDuration = forward;
    _skipBackDuration = back;
  }

  StreamSubscription<PlaybackState>? _playbackSubscription;
  StreamSubscription<ProcessingState>? _processingStateSub;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;

  bool _disposed = false;
  bool _wasPlayingBeforeInterruption = false;

  MediaItem? _currentMediaItem;
  MediaItem? _nextMediaItem;

  // Tracks previous index to detect forward advances in the playlist.
  int? _lastKnownIndex;

  // Prevents re-entrant processing when removeAudioSourceAt(0) fires a
  // currentIndexStream event.
  bool _isAdvancing = false;

  // True once the player has reached ready since the last load. Gates the
  // completed listener so completion-on-load (restore at/past media end)
  // can't masquerade as a finished episode.
  bool _readySinceLoad = false;

  // True once playback has been requested since the last load. Sticky on
  // purpose: a pause arriving at the exact media end must not suppress a
  // genuine completion, and loadEpisode never requests playback so a
  // restore can never set it.
  bool _playRequestedSinceLoad = false;

  // Guards against re-entrant completion handling. _onEpisodeCompleted is
  // fired via unawaited(...) from the processing-state listener, so two
  // completed events in rapid succession could otherwise run it concurrently
  // and restart whichever episode the first invocation just started. Set
  // synchronously at the top of _onEpisodeCompleted and cleared only in its
  // finally — never reset elsewhere, since clearing it mid-flight (e.g. when
  // the awaited callback calls playEpisode/stop) would re-open the reentrancy
  // window for an already-queued second invocation.
  bool _completionInProgress = false;

  /// Called when the playlist advances gaplessly to the next episode.
  /// [previousEpisodeId] is the episode that just finished.
  Future<void> Function(int? previousEpisodeId)? onEpisodeAdvanced;

  /// Called when the last episode in the playlist finishes.
  Future<void> Function()? onEpisodeCompleted;

  void _attachPlaybackListener() {
    _playbackSubscription = _player.playbackEventStream
        .map(_buildPlaybackState)
        .listen(playbackState.add);
  }

  void _attachProcessingStateListener() {
    _processingStateSub = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.ready) _readySinceLoad = true;
      if (state == ProcessingState.completed) {
        switch (classifyCompleted(
          isAdvancing: _isAdvancing,
          readySinceLoad: _readySinceLoad,
          playRequestedSinceLoad: _playRequestedSinceLoad,
        )) {
          case CompletedAction.ignoreAdvancing:
            // This completion belongs to the episode being advanced past, not
            // the newly-promoted current episode. Honoring it would mark the
            // new episode played and remove it from the queue mid-playback.
            _log.warning('Ignoring completed event during gapless advance');
          case CompletedAction.ignoreSpurious:
            _log.warning(
              'Ignoring spurious completed event (no playback since load)',
            );
          case CompletedAction.honor:
            unawaited(_onEpisodeCompleted());
        }
      }
    });
  }

  void _attachIndexListener() {
    _indexSub = _player.currentIndexStream.listen((index) {
      final last = _lastKnownIndex;
      _lastKnownIndex = index;
      if (index == null || last == null) return;
      if (index > last && !_isAdvancing) {
        _isAdvancing = true;
        unawaited(_onGaplessAdvance());
      }
    });
  }

  final StreamController<int?> _episodeIdController =
      StreamController<int?>.broadcast();
  Stream<int?> get episodeIdStream => _episodeIdController.stream;

  /// The episodeId of the currently-loaded episode, or null if none.
  int? get currentEpisodeId => _currentMediaItem?.extras?['episodeId'] as int?;

  /// The episodeId of the preloaded next episode, or null if nothing is
  /// preloaded for a gapless transition.
  int? get preloadedNextEpisodeId =>
      _nextMediaItem?.extras?['episodeId'] as int?;

  /// True while a gapless advance is in flight.
  bool get isAdvancing => _isAdvancing;

  /// Drops any preloaded next episode and removes its buffered audio source, so
  /// it can't play gaplessly. Used when the queue changes and the preloaded
  /// item is no longer the correct next episode (#297). The episode currently
  /// playing (source at index 0) is untouched.
  Future<void> clearPreloadedNext() async {
    _nextMediaItem = null;
    while (_player.audioSources.length > 1) {
      await _player.removeAudioSourceAt(_player.audioSources.length - 1);
    }
  }

  AudioSource _resolveAudioSource(MediaItem item) => resolveAudioSource(item);

  Future<void> _applyPlaybackSettings(MediaItem item) async {
    // Read per-podcast overrides directly from the DB so we always get the
    // freshest value regardless of what the caller put in extras. The extras
    // extras can be stale when the Riverpod StreamProvider hasn't processed
    // the latest DB write yet (AsyncLoading race on first read).
    double? speedOverride;
    bool? trimSilenceOverride;
    final podcastId = item.extras?['podcastId'] as int?;
    if (_db != null && podcastId != null) {
      final row = await (_db!.select(
        _db!.podcasts,
      )..where((p) => p.id.equals(podcastId))).getSingleOrNull();
      speedOverride = row?.speedOverride;
      trimSilenceOverride = row?.trimSilenceOverride;
    }

    final globalSpeed = await _settings?.getGlobalSpeed() ?? 1.0;
    final speed = speedOverride ?? globalSpeed;
    await _player.setSpeed(speed);
    playbackState.add(playbackState.value.copyWith(speed: speed));

    final globalTrimSilence = await _settings?.isSkipSilenceEnabled() ?? false;
    await _player.setSkipSilenceEnabled(
      trimSilenceOverride ?? globalTrimSilence,
    );
  }

  Future<void> playEpisode(
    MediaItem item, {
    int resumePositionSeconds = 0,
  }) async {
    _log.info('Playing: ${item.title}');
    _readySinceLoad = false;
    _playRequestedSinceLoad = false;
    _currentMediaItem = item;
    _nextMediaItem = null;
    _lastKnownIndex = 0;
    mediaItem.add(item);
    queue.add([item]);

    final episodeId = item.extras?['episodeId'] as int?;
    _episodeIdController.add(episodeId);

    await _applyPlaybackSettings(item);

    try {
      await _player.setAudioSources(
        [_resolveAudioSource(item)],
        initialIndex: 0,
        initialPosition: Duration(seconds: resumePositionSeconds),
      );
      _playRequestedSinceLoad = true;
      await _player.play();
    } on Exception catch (e) {
      _log.severe('Failed to load audio for "${item.title}": $e');
      mediaItem.add(null);
      await stop();
    }
  }

  Future<void> loadEpisode(
    MediaItem item, {
    int resumePositionSeconds = 0,
  }) async {
    _log.info('Restoring: ${item.title}');
    _readySinceLoad = false;
    _playRequestedSinceLoad = false;
    _currentMediaItem = item;
    _nextMediaItem = null;
    _lastKnownIndex = 0;
    mediaItem.add(item);
    queue.add([item]);

    final episodeId = item.extras?['episodeId'] as int?;
    _episodeIdController.add(episodeId);

    await _applyPlaybackSettings(item);

    try {
      await _player.setAudioSources(
        [_resolveAudioSource(item)],
        initialIndex: 0,
        initialPosition: Duration(seconds: resumePositionSeconds),
      );
    } on Exception catch (e) {
      _log.severe('Failed to restore "${item.title}": $e');
      mediaItem.add(null);
      await stop();
    }
  }

  /// Adds [item] as the next item in the playlist so just_audio can
  /// buffer and transition gaplessly. Replaces any previously preloaded item.
  Future<void> preloadNext(MediaItem item) async {
    _nextMediaItem = item;
    // Drop any stale preloaded item before adding the new one.
    while (_player.audioSources.length > 1) {
      await _player.removeAudioSourceAt(_player.audioSources.length - 1);
    }
    await _player.addAudioSource(_resolveAudioSource(item));
    _log.info('Preloaded next: ${item.title}');
  }

  Future<void> _onGaplessAdvance() async {
    _log.info(
      'Gapless advance: ${_currentMediaItem?.title} → ${_nextMediaItem?.title}',
    );
    final previousEpisodeId = _currentMediaItem?.extras?['episodeId'] as int?;
    final next = _nextMediaItem;

    try {
      if (next != null) {
        _currentMediaItem = next;
        _nextMediaItem = null;
        mediaItem.add(next);

        final episodeId = next.extras?['episodeId'] as int?;
        _episodeIdController.add(episodeId);

        await _applyPlaybackSettings(next);

        // Remove the completed episode from the playlist head.
        // This causes currentIndexStream to emit 0; _isAdvancing suppresses it.
        await _player.removeAudioSourceAt(0);
      }

      sleepTimer.onEpisodeEnded();
      final callback = onEpisodeAdvanced;
      if (callback != null) {
        await callback(previousEpisodeId);
      }
    } finally {
      _isAdvancing = false;
    }
  }

  @override
  Future<void> fastForward() => _seekBy(_skipForwardDuration);

  @override
  Future<void> rewind() => _seekBy(-_skipBackDuration);

  // AirPods double-click fires skipToNext(). Remap to skip forward.
  @override
  Future<void> skipToNext() => _seekBy(_skipForwardDuration);

  // AirPods triple-click fires skipToPrevious(). Remap to skip back.
  @override
  Future<void> skipToPrevious() => _seekBy(-_skipBackDuration);

  Future<void> _seekBy(Duration offset) async {
    var pos = _player.position + offset;
    if (pos < Duration.zero) pos = Duration.zero;
    final dur = _player.duration;
    if (dur != null && pos > dur) pos = dur;
    await _player.seek(pos);
  }

  @override
  Future<void> play() {
    _playRequestedSinceLoad = true;
    return _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _playbackSubscription?.cancel();
    _playbackSubscription = null;
    await _processingStateSub?.cancel();
    _processingStateSub = null;
    await _indexSub?.cancel();
    _indexSub = null;
    _currentMediaItem = null;
    _nextMediaItem = null;
    _lastKnownIndex = null;
    _isAdvancing = false;
    _readySinceLoad = false;
    _playRequestedSinceLoad = false;
    await _player.stop();
    _episodeIdController.add(null);
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
    _attachPlaybackListener();
    _attachIndexListener();
    _attachProcessingStateListener();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
    playbackState.add(playbackState.value.copyWith(speed: speed));
  }

  Future<void> setSkipSilenceEnabled(bool enabled) async {
    await _player.setSkipSilenceEnabled(enabled);
    _log.info('Skip silence: $enabled');
  }

  // Android only: loudness normalization via AndroidLoudnessEnhancer.
  // iOS Voice Boost is not shown in the UI (AVQueuePlayer cannot host
  // AVAudioEngine EQ nodes). This method is therefore only called on Android.
  Future<void> setVoiceEnhance(bool enabled) async {
    try {
      await _loudnessEnhancer.setEnabled(enabled);
      if (enabled) await _loudnessEnhancer.setTargetGain(500);
    } on Exception {
      _log.warning('setVoiceEnhance failed: $enabled');
    }
    _log.info('Voice enhance: $enabled');
  }

  Duration get position => _player.position;

  Stream<Duration> get positionStream => _player.positionStream;

  PlaybackState _buildPlaybackState(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.rewind,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.fastForward,
        MediaAction.rewind,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: _mapProcessingState(_player.processingState),
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
    );
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) =>
      switch (state) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      };

  Future<void> _onEpisodeCompleted() async {
    if (_completionInProgress) {
      _log.warning('_onEpisodeCompleted called re-entrantly, ignoring');
      return;
    }
    _completionInProgress = true;
    try {
      _log.info('Episode completed: ${mediaItem.value?.title}');
      sleepTimer.onEpisodeEnded();
      final callback = onEpisodeCompleted;
      if (callback != null) {
        await callback();
      } else {
        await stop();
      }
    } finally {
      _completionInProgress = false;
    }
  }

  /// Marks the currently-playing episode as played and advances exactly as if
  /// it had finished on its own: the episode is removed from the queue, its
  /// saved position is cleared, and playback moves to the next queued episode
  /// (or stops when the queue is empty). Used by the "Mark as played" action on
  /// the Now Playing screen so the user doesn't have to let an episode run to
  /// the end to be rid of it. Routes through the same completion path so the
  /// re-entrancy guard, group boundaries, and continue-after-queue setting are
  /// all honored.
  Future<void> markCurrentEpisodePlayed() => _onEpisodeCompleted();

  Future<void> dispose() async {
    _disposed = true;
    sleepTimer.dispose();
    await _playbackSubscription?.cancel();
    await _processingStateSub?.cancel();
    await _indexSub?.cancel();
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
    await _episodeIdController.close();
    await _player.dispose();
  }
}
