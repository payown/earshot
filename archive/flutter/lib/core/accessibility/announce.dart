import 'dart:async';
import 'dart:ui';

import 'package:flutter/semantics.dart';

/// Delay before announcing after a modal sheet/dialog closes. Long enough for
/// the dismiss animation and the focus change back to the trigger to settle, so
/// iOS VoiceOver doesn't discard the announcement mid focus-transition.
const _kPostDismissAnnounceDelay = Duration(milliseconds: 450);

/// Announces [message] to the screen reader after a modal sheet/dialog has
/// closed.
///
/// A `SemanticsService.sendAnnouncement` fired immediately after a sheet pops is
/// swallowed on iOS: closing the sheet moves VoiceOver focus back to the trigger
/// row, and that focus change clears the queued (polite) announcement. Delaying
/// past the dismiss + focus settle lets the announcement actually be spoken.
///
/// Capture [view] (e.g. `View.of(context)`) at the call site while the context
/// is still mounted; the announcement is scheduled and fired in the background.
void announceAfterDismiss(FlutterView view, String message) {
  Timer(_kPostDismissAnnounceDelay, () {
    SemanticsService.sendAnnouncement(view, message, TextDirection.ltr);
  });
}
