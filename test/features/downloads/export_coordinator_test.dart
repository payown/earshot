import 'dart:async';
import 'dart:io';

import 'package:earshot/features/downloads/data/download_manager.dart';
import 'package:earshot/features/downloads/data/export_coordinator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockDownloadManager extends Mock implements DownloadManager {}

void main() {
  late _MockDownloadManager mgr;
  late StreamController<DownloadOutcome> outcomes;
  late GlobalKey<ScaffoldMessengerState> messengerKey;
  late List<(File, String?)> shared;
  ExportCoordinator? coordinator;

  late File tempFile;

  setUp(() async {
    mgr = _MockDownloadManager();
    outcomes = StreamController<DownloadOutcome>.broadcast();
    messengerKey = GlobalKey<ScaffoldMessengerState>();
    shared = [];
    when(() => mgr.downloadOutcomes).thenAnswer((_) => outcomes.stream);
    tempFile = await File(
      '${Directory.systemTemp.path}/export_coord_${DateTime.now().microsecondsSinceEpoch}.mp3',
    ).create();
  });

  tearDown(() async {
    coordinator?.dispose();
    await outcomes.close();
    if (tempFile.existsSync()) await tempFile.delete();
  });

  ExportCoordinator build() => coordinator = ExportCoordinator(
    downloadManager: mgr,
    messengerKey: messengerKey,
    share: (file, subject) async => shared.add((file, subject)),
  );

  group('without a mounted messenger (pure logic)', () {
    test('already downloaded → shares immediately', () async {
      when(
        () => mgr.downloadEpisode(1, force: true),
      ).thenAnswer((_) async => DownloadStartResult.alreadyDownloaded);
      when(() => mgr.prepareExportFile(1)).thenAnswer((_) async => tempFile);

      await build().requestExport(1, subject: 'Ep');
      await pumpEventQueue();

      expect(shared, [(tempFile, 'Ep')]);
    });

    test('started → shares when a success outcome arrives', () async {
      when(
        () => mgr.downloadEpisode(7, force: true),
      ).thenAnswer((_) async => DownloadStartResult.started);
      when(() => mgr.prepareExportFile(7)).thenAnswer((_) async => tempFile);

      await build().requestExport(7, subject: 'Ep7');
      expect(shared, isEmpty); // not shared yet — download in flight

      outcomes.add(const DownloadOutcome.success(7));
      await pumpEventQueue();

      expect(shared, [(tempFile, 'Ep7')]);
    });

    test('does not share on a failure outcome', () async {
      when(
        () => mgr.downloadEpisode(7, force: true),
      ).thenAnswer((_) async => DownloadStartResult.started);

      await build().requestExport(7);
      outcomes.add(
        const DownloadOutcome.failure(
          7,
          DownloadFailureReason.networkOrUnknown,
        ),
      );
      await pumpEventQueue();

      expect(shared, isEmpty);
      verifyNever(() => mgr.prepareExportFile(any()));
    });

    test('ignores outcomes for episodes it is not tracking', () async {
      build();
      outcomes.add(const DownloadOutcome.success(999));
      await pumpEventQueue();

      expect(shared, isEmpty);
      verifyNever(() => mgr.prepareExportFile(any()));
    });
  });

  group('with a mounted messenger (SnackBars)', () {
    Future<void> pumpMessenger(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: messengerKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );

    testWidgets('started shows a "Downloading for export…" SnackBar', (
      tester,
    ) async {
      when(
        () => mgr.downloadEpisode(1, force: true),
      ).thenAnswer((_) async => DownloadStartResult.started);
      await pumpMessenger(tester);

      await build().requestExport(1);
      await tester.pump();

      expect(find.text('Downloading for export…'), findsOneWidget);
    });

    testWidgets('notFound shows the "can\'t be downloaded" message', (
      tester,
    ) async {
      when(
        () => mgr.downloadEpisode(1, force: true),
      ).thenAnswer((_) async => DownloadStartResult.notFound);
      await pumpMessenger(tester);

      await build().requestExport(1);
      await tester.pump();

      expect(find.textContaining("can't be downloaded"), findsOneWidget);
    });

    testWidgets('a network failure shows a retry SnackBar that re-requests', (
      tester,
    ) async {
      when(
        () => mgr.downloadEpisode(3, force: true),
      ).thenAnswer((_) async => DownloadStartResult.started);
      await pumpMessenger(tester);

      await build().requestExport(3, subject: 'E3');
      outcomes.add(
        const DownloadOutcome.failure(
          3,
          DownloadFailureReason.networkOrUnknown,
        ),
      );
      await tester.pump(); // deliver the outcome
      await tester.pump(const Duration(seconds: 1)); // settle SnackBar entrance

      expect(find.textContaining('Export failed'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pump();

      // Retry re-invokes the forced download (once for the initial request,
      // once for the retry).
      verify(() => mgr.downloadEpisode(3, force: true)).called(2);
    });

    testWidgets('an "unavailable" failure shows the dead-URL message', (
      tester,
    ) async {
      when(
        () => mgr.downloadEpisode(5, force: true),
      ).thenAnswer((_) async => DownloadStartResult.started);
      await pumpMessenger(tester);

      await build().requestExport(5);
      outcomes.add(
        const DownloadOutcome.failure(5, DownloadFailureReason.unavailable),
      );
      await tester.pump();

      expect(find.textContaining("can't be downloaded"), findsOneWidget);
    });
  });
}
