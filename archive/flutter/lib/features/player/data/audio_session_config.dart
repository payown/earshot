import 'package:audio_session/audio_session.dart';

/// Audio session configuration for long-form spoken-word playback.
///
/// Sets the iOS category to `.playback` with `.allowAirPlay` and the
/// `.longFormAudio` route sharing policy, which is what makes the system
/// proactively offer AirPlay devices as output routes for podcasts. Without
/// an explicit configuration, the session stays on iOS's default
/// `.soloAmbient` category, which does not support AirPlay route sharing.
const AudioSessionConfiguration earshotAudioSessionConfiguration =
    AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowAirPlay,
      avAudioSessionMode: AVAudioSessionMode.spokenAudio,
      avAudioSessionRouteSharingPolicy:
          AVAudioSessionRouteSharingPolicy.longFormAudio,
      avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: true,
    );
