import 'package:earshot/core/utils/url_launcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakeLauncher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final List<String> launched = [];

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

void main() {
  late _FakeLauncher fakeLauncher;

  setUp(() {
    fakeLauncher = _FakeLauncher();
    UrlLauncherPlatform.instance = fakeLauncher;
  });

  group('safeLaunchUrl', () {
    test('launches http URLs', () async {
      await safeLaunchUrl('http://example.com/feed.mp3');
      expect(fakeLauncher.launched, ['http://example.com/feed.mp3']);
    });

    test('launches https URLs', () async {
      await safeLaunchUrl('https://example.com/episode');
      expect(fakeLauncher.launched, ['https://example.com/episode']);
    });

    test('launches mailto URLs', () async {
      await safeLaunchUrl('mailto:hello@example.com');
      expect(fakeLauncher.launched, ['mailto:hello@example.com']);
    });

    test('blocks intent:// URLs', () async {
      await safeLaunchUrl('intent://example.com#Intent;scheme=http;end');
      expect(fakeLauncher.launched, isEmpty);
    });

    test('blocks tel: URLs', () async {
      await safeLaunchUrl('tel:+15551234567');
      expect(fakeLauncher.launched, isEmpty);
    });

    test('blocks file:// URLs', () async {
      await safeLaunchUrl('file:///etc/passwd');
      expect(fakeLauncher.launched, isEmpty);
    });

    test('blocks custom app scheme URLs', () async {
      await safeLaunchUrl('myapp://open/thing');
      expect(fakeLauncher.launched, isEmpty);
    });

    test('silently ignores unparseable URLs', () async {
      await safeLaunchUrl('not a url !!!');
      expect(fakeLauncher.launched, isEmpty);
    });
  });
}
