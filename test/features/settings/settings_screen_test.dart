import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/core/router/app_router.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/features/settings/presentation/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _FakeLauncher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final List<String> launched = [];
  bool canLaunchResult = true;

  @override
  Future<bool> canLaunch(String url) async => canLaunchResult;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return canLaunchResult;
  }
}

void main() {
  late AppDatabase db;
  late _FakeLauncher fakeLauncher;
  late UrlLauncherPlatform originalLauncherPlatform;

  const packageInfoChannel = MethodChannel(
    'dev.fluttercommunity.plus/package_info',
  );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    originalLauncherPlatform = UrlLauncherPlatform.instance;
    fakeLauncher = _FakeLauncher();
    UrlLauncherPlatform.instance = fakeLauncher;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfoChannel, (call) async {
          if (call.method == 'getAll') {
            return <String, dynamic>{
              'appName': 'Earshot',
              'packageName': 'media.payown.earshot',
              'version': '1.2.3',
              'buildNumber': '99',
              'buildSignature': '',
            };
          }
          return null;
        });
  });

  tearDown(() async {
    await db.close();
    UrlLauncherPlatform.instance = originalLauncherPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfoChannel, null);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const SettingsScreen()),
        GoRoute(
          path: AppRoutes.tutorial,
          builder: (_, __) => const Scaffold(body: Text('Tutorial Screen')),
        ),
        GoRoute(
          path: AppRoutes.settingsGeneral,
          builder: (_, __) => const Scaffold(body: Text('General Screen')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows a View Tutorial entry', (tester) async {
    await pumpScreen(tester);

    await tester.scrollUntilVisible(
      find.text('View Tutorial'),
      200,
      scrollable: find.byType(Scrollable),
    );

    expect(find.text('View Tutorial'), findsOneWidget);
  });

  testWidgets('tapping View Tutorial navigates to the tutorial route', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.scrollUntilVisible(
      find.text('View Tutorial'),
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.tap(find.text('View Tutorial'));
    await tester.pumpAndSettle();

    expect(find.text('Tutorial Screen'), findsOneWidget);
  });

  testWidgets('shows a General entry', (tester) async {
    await pumpScreen(tester);

    expect(find.text('General'), findsOneWidget);
  });

  testWidgets('tapping General navigates to the general settings route', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.text('General'));
    await tester.pumpAndSettle();

    expect(find.text('General Screen'), findsOneWidget);
  });

  testWidgets('shows a Send Feedback entry', (tester) async {
    await pumpScreen(tester);

    await tester.scrollUntilVisible(
      find.text('Send Feedback'),
      200,
      scrollable: find.byType(Scrollable),
    );

    expect(find.text('Send Feedback'), findsOneWidget);
    expect(
      find.text('Email the developer with thoughts or ideas'),
      findsOneWidget,
    );
  });

  testWidgets(
    'tapping Send Feedback launches a mailto link with version and build '
    'number',
    (tester) async {
      await pumpScreen(tester);

      await tester.scrollUntilVisible(
        find.text('Send Feedback'),
        200,
        scrollable: find.byType(Scrollable),
      );
      await tester.tap(find.text('Send Feedback'));
      await tester.pumpAndSettle();

      expect(fakeLauncher.launched, hasLength(1));
      final raw = fakeLauncher.launched.single;
      // Spaces and '+' must be percent-encoded as %20/%2B, not '+', so mail
      // clients don't render literal '+' characters in the subject.
      expect(
        raw,
        'mailto:michael@payown.media?subject=Earshot%20Feedback%20(v1.2.3%2B99)',
      );
      final uri = Uri.parse(raw);
      expect(uri.scheme, 'mailto');
      expect(uri.path, 'michael@payown.media');
      expect(
        uri.queryParameters['subject'],
        'Earshot Feedback (v1.2.3+99)',
      );
    },
  );

  testWidgets(
    'shows a fallback message when no email app is available',
    (tester) async {
      fakeLauncher.canLaunchResult = false;
      await pumpScreen(tester);

      await tester.scrollUntilVisible(
        find.text('Send Feedback'),
        200,
        scrollable: find.byType(Scrollable),
      );
      await tester.tap(find.text('Send Feedback'));
      await tester.pumpAndSettle();

      expect(
        find.text('No email app found. Email us at michael@payown.media'),
        findsOneWidget,
      );
    },
  );
}
