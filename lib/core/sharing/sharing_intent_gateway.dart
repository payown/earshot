import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';

/// Provides incoming shared/opened file paths from other apps.
///
/// Wraps `share_handler` so the rest of the app depends only on file paths,
/// not the package's [SharedMedia]/[SharedAttachment] types.
abstract interface class SharingIntentGateway {
  /// Returns the file the app was launched with (cold start), or an empty
  /// list if the app wasn't launched via a share/open action.
  Future<List<String>> getInitialSharedFiles();

  /// Emits file paths shared to the app while it's already running.
  Stream<List<String>> get sharedFileStream;
}

class ShareHandlerGateway implements SharingIntentGateway {
  ShareHandlerGateway({ShareHandlerPlatform? handler})
    : _handler = handler ?? ShareHandlerPlatform.instance;

  final ShareHandlerPlatform _handler;

  @override
  Future<List<String>> getInitialSharedFiles() async {
    final media = await _handler.getInitialSharedMedia();
    return _opmlPaths(media);
  }

  @override
  Stream<List<String>> get sharedFileStream =>
      _handler.sharedMediaStream.map(_opmlPaths);

  List<String> _opmlPaths(SharedMedia? media) =>
      (media?.attachments ?? const [])
          .map((attachment) => attachment?.path)
          .whereType<String>()
          .where(
            (path) =>
                path.toLowerCase().endsWith('.opml') ||
                path.toLowerCase().endsWith('.xml'),
          )
          .toList();
}

final sharingIntentGatewayProvider = Provider<SharingIntentGateway>(
  (_) => ShareHandlerGateway(),
);
