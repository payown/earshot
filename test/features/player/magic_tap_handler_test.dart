import 'package:earshot/features/player/data/magic_tap_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // SemanticsService.announce posts on a system channel, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late bool hasMedia;
  late bool playing;
  late int playCalls;
  late int pauseCalls;
  late MagicTapHandler handler;

  setUp(() {
    hasMedia = true;
    playing = false;
    playCalls = 0;
    pauseCalls = 0;
    handler = MagicTapHandler(
      hasMedia: () => hasMedia,
      isPlaying: () => playing,
      play: () async {
        playCalls++;
        playing = true;
      },
      pause: () async {
        pauseCalls++;
        playing = false;
      },
      // Avoid registering a handler on the production channel name.
      channel: const MethodChannel('test/magic_tap'),
    );
  });

  test('plays when an episode is loaded and paused', () async {
    playing = false;

    await handler.handleMagicTap();

    expect(playCalls, 1);
    expect(pauseCalls, 0);
  });

  test('pauses when an episode is loaded and playing', () async {
    playing = true;

    await handler.handleMagicTap();

    expect(pauseCalls, 1);
    expect(playCalls, 0);
  });

  test('does nothing to playback when no episode is loaded', () async {
    hasMedia = false;

    await handler.handleMagicTap();

    expect(playCalls, 0);
    expect(pauseCalls, 0);
  });
}
