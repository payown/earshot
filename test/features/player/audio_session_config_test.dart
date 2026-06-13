import 'package:audio_session/audio_session.dart';
import 'package:earshot/features/player/data/audio_session_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('earshotAudioSessionConfiguration', () {
    const config = earshotAudioSessionConfiguration;

    test('uses the playback category', () {
      expect(config.avAudioSessionCategory, AVAudioSessionCategory.playback);
    });

    test('allows AirPlay as an output route', () {
      expect(
        config.avAudioSessionCategoryOptions?.contains(
          AVAudioSessionCategoryOptions.allowAirPlay,
        ),
        isTrue,
      );
    });

    test('uses the spoken audio mode', () {
      expect(config.avAudioSessionMode, AVAudioSessionMode.spokenAudio);
    });

    test('uses the long-form audio route sharing policy', () {
      expect(
        config.avAudioSessionRouteSharingPolicy,
        AVAudioSessionRouteSharingPolicy.longFormAudio,
      );
    });

    test('uses speech content type and media usage on Android', () {
      final attributes = config.androidAudioAttributes;
      expect(attributes?.contentType, AndroidAudioContentType.speech);
      expect(attributes?.usage, AndroidAudioUsage.media);
    });

    test('requests audio focus gain and pauses when ducked on Android', () {
      expect(
        config.androidAudioFocusGainType,
        AndroidAudioFocusGainType.gain,
      );
      expect(config.androidWillPauseWhenDucked, isTrue);
    });
  });
}
