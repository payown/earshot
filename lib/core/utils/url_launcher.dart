import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

final _log = Logger('UrlLauncher');

const _allowedSchemes = {'http', 'https', 'mailto'};

/// Launches [url] only when its scheme is http, https, or mailto.
/// Logs a warning and no-ops for anything else (intent://, tel:, custom app
/// schemes, etc.) to prevent podcast-supplied links from triggering unintended
/// behaviour.
Future<void> safeLaunchUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  if (!_allowedSchemes.contains(uri.scheme)) {
    _log.warning('Blocked launch of disallowed scheme: ${uri.scheme}');
    return;
  }
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
