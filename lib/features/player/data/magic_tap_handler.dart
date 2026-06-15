import 'dart:ui' as ui;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

/// Channel the native side ([AppDelegate.accessibilityPerformMagicTap]) invokes
/// when VoiceOver's two-finger double-tap ("magic tap") fires.
const _magicTapChannel = MethodChannel('media.payown.earshot/magic_tap');

/// Bridges the iOS VoiceOver "magic tap" to global play/pause.
///
/// Flutter exposes no magic-tap API, so the gesture is caught natively in
/// `AppDelegate` and forwarded over [_magicTapChannel]. Magic tap is meant to
/// be a global, focus-independent shortcut, so this toggles playback from
/// anywhere in the app whenever an episode is loaded, then announces the
/// resulting state to VoiceOver (matching the "Playing"/"Paused" status
/// announcements used elsewhere).
///
/// State and actions are injected as callbacks rather than taking the audio
/// handler directly, so the toggle logic is unit-testable without standing up
/// `audio_service`.
class MagicTapHandler {
  MagicTapHandler({
    required bool Function() hasMedia,
    required bool Function() isPlaying,
    required Future<void> Function() play,
    required Future<void> Function() pause,
    MethodChannel channel = _magicTapChannel,
  }) : _hasMedia = hasMedia,
       _isPlaying = isPlaying,
       _play = play,
       _pause = pause,
       _channel = channel {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'performMagicTap') {
        await handleMagicTap();
      }
    });
  }

  final bool Function() _hasMedia;
  final bool Function() _isPlaying;
  final Future<void> Function() _play;
  final Future<void> Function() _pause;
  final MethodChannel _channel;

  /// Toggles play/pause and announces the result to VoiceOver. Public for
  /// testing; in the app it is only invoked by the native magic-tap handler.
  Future<void> handleMagicTap() async {
    if (!_hasMedia()) {
      // Nothing to toggle, but stay quiet-but-confirming rather than silent so
      // the user knows the gesture registered.
      _announce('Nothing playing');
      return;
    }
    // Announce the intended resulting state. Brief buffering after resume is
    // normal podcast behaviour; pause is immediate.
    if (_isPlaying()) {
      await _pause();
      _announce('Paused');
    } else {
      await _play();
      _announce('Playing');
    }
  }

  void _announce(String message) {
    // No BuildContext here (this runs from a platform-channel callback), so
    // route the announcement through the single implicit view.
    final view = ui.PlatformDispatcher.instance.implicitView;
    if (view == null) return;
    SemanticsService.sendAnnouncement(view, message, TextDirection.ltr);
  }
}
