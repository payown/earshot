import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// An in-app AirPlay output picker, backed by a native `AVRoutePickerView`.
///
/// `AVRoutePickerView` provides its own VoiceOver label ("AirPlay") and tap
/// handling, so this widget must not be wrapped in a [Semantics] button or a
/// gesture detector — doing so creates a nested-button VoiceOver bug where
/// double-tap stops opening the route picker.
///
/// AirPlay is iOS-only, so this renders nothing on other platforms.
class AirPlayButton extends StatelessWidget {
  const AirPlayButton({super.key});

  static const _viewType = 'media.payown.earshot/airplay_button';

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return const SizedBox.shrink();
    }

    return const SizedBox(
      width: 44,
      height: 44,
      child: UiKitView(
        viewType: _viewType,
        creationParamsCodec: StandardMessageCodec(),
      ),
    );
  }
}
