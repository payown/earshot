import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// Hands an already-prepared audio [file] (see
/// `DownloadManager.prepareExportFile`) to the OS share sheet — Save to Files,
/// AirDrop, open-in another app, etc. Shared by the episode actions/player
/// export flow and the background export coordinator so both behave identically.
///
/// Lives in its own file (not in `episode_action_builder.dart`) so the
/// coordinator can reuse it without an import cycle.
Future<void> shareExportedAudioFile(File file, {String? subject}) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile(file.path, mimeType: audioMimeForExt(p.extension(file.path))),
      ],
      subject: subject,
    ),
  );
}

/// Best-effort MIME type from a file extension. The downloaded file keeps its
/// original container, so this is a hint for the share sheet, not a guarantee.
String audioMimeForExt(String ext) => switch (ext.toLowerCase()) {
  '.mp3' => 'audio/mpeg',
  '.m4a' || '.mp4' || '.aac' => 'audio/mp4',
  '.ogg' || '.oga' => 'audio/ogg',
  '.wav' => 'audio/wav',
  '.flac' => 'audio/flac',
  _ => 'audio/mpeg',
};
