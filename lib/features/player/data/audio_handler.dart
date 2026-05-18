import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';

final _log = Logger('AudioHandler');

class EarshotAudioHandler extends BaseAudioHandler with SeekHandler {
  EarshotAudioHandler() {
    _player.playbackEventStream.map(_buildPlaybackState).pipe(playbackState);

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _onEpisodeCompleted();
      }
    });
  }

  final AudioPlayer _player = AudioPlayer();

  Future<void> playEpisode(MediaItem item) async {
    _log.info('Playing: ${item.title}');
    mediaItem.add(item);
    queue.add([item]);
    try {
      await _player.setUrl(item.id);
      await _player.play();
    } on Exception catch (e) {
      _log.severe('Failed to load audio: $e');
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  // SeekHandler provides fastForward and rewind using configured intervals.

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

  void _onEpisodeCompleted() {
    _log.info('Episode completed: ${mediaItem.value?.title}');
    stop();
  }

  Future<void> dispose() => _player.dispose();
}
