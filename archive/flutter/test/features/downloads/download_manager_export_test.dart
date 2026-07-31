import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/downloads/data/download_manager.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Returns a real on-disk temp directory so `getTemporaryDirectory()` works in
/// unit tests (the export copies the download into it).
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempPath);
  final String tempPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // FileDownloader().updates is a single-subscription stream on a process-wide
  // singleton, so the manager (which listens to it in its constructor) is built
  // once for the whole file rather than per test. Each test inserts rows with
  // fresh autoincrement ids, so no cross-test state leaks.
  late AppDatabase db;
  late DownloadManager manager;
  late Directory tempDir;
  late Directory downloadsDir;

  setUpAll(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    manager = DownloadManager(
      database: db,
      settings: AppSettingsRepositoryImpl(database: db),
    );
  });

  tearDownAll(() async {
    await manager.dispose();
    await db.close();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('earshot_export_tmp');
    downloadsDir = await Directory.systemTemp.createTemp('earshot_export_dl');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    if (downloadsDir.existsSync()) await downloadsDir.delete(recursive: true);
  });

  Future<int> addPodcast(String title) => db
      .into(db.podcasts)
      .insert(
        PodcastsCompanion.insert(
          rssUrl:
              'https://example.com/${DateTime.now().microsecondsSinceEpoch}.xml',
          title: title,
        ),
      );

  Future<int> addEpisode(
    int podcastId, {
    required String title,
    required DownloadStatus status,
    String? downloadPath,
    String ext = '.mp3',
  }) => db
      .into(db.episodes)
      .insert(
        EpisodesCompanion.insert(
          podcastId: podcastId,
          guid: 'g-${DateTime.now().microsecondsSinceEpoch}',
          title: title,
          audioUrl: 'https://example.com/audio$ext',
          downloadStatus: Value(status),
          downloadPath: Value(downloadPath),
        ),
      );

  /// Writes a fake downloaded file on disk and returns its path.
  Future<String> writeDownload(int episodeId, {String ext = '.mp3'}) async {
    final f = File(p.join(downloadsDir.path, 'ep_$episodeId$ext'));
    await f.writeAsString('fake-audio-bytes');
    return f.path;
  }

  test('returns a friendly-named copy for a downloaded episode', () async {
    final pid = await addPodcast('My Show');
    final eid = await addEpisode(
      pid,
      title: 'Episode One',
      status: DownloadStatus.downloaded,
    );
    final srcPath = await writeDownload(eid);
    await (db.update(db.episodes)..where((e) => e.id.equals(eid))).write(
      EpisodesCompanion(downloadPath: Value(srcPath)),
    );

    final result = await manager.prepareExportFile(eid);

    expect(result, isNotNull);
    expect(p.basename(result!.path), 'My Show - Episode One.mp3');
    expect(p.dirname(result.path), tempDir.path);
    expect(await result.readAsString(), 'fake-audio-bytes');
  });

  test('preserves the real extension (not forced to .mp3)', () async {
    final pid = await addPodcast('Show');
    final eid = await addEpisode(
      pid,
      title: 'Ep',
      status: DownloadStatus.downloaded,
      ext: '.m4a',
    );
    final srcPath = await writeDownload(eid, ext: '.m4a');
    await (db.update(db.episodes)..where((e) => e.id.equals(eid))).write(
      EpisodesCompanion(downloadPath: Value(srcPath)),
    );

    final result = await manager.prepareExportFile(eid);

    expect(p.extension(result!.path), '.m4a');
  });

  test('sanitizes filesystem-illegal characters in the name', () async {
    final pid = await addPodcast('AC/DC: Live');
    final eid = await addEpisode(
      pid,
      title: 'Part 1/2 "Best"',
      status: DownloadStatus.downloaded,
    );
    final srcPath = await writeDownload(eid);
    await (db.update(db.episodes)..where((e) => e.id.equals(eid))).write(
      EpisodesCompanion(downloadPath: Value(srcPath)),
    );

    final result = await manager.prepareExportFile(eid);

    final name = p.basename(result!.path);
    expect(name.contains('/'), isFalse);
    expect(name.contains(':'), isFalse);
    expect(name.contains('"'), isFalse);
    expect(name.endsWith('.mp3'), isTrue);
  });

  test('returns null for an episode that is not downloaded', () async {
    final pid = await addPodcast('Show');
    final eid = await addEpisode(
      pid,
      title: 'Ep',
      status: DownloadStatus.none,
    );

    expect(await manager.prepareExportFile(eid), isNull);
  });

  test('returns null when downloadPath points at a missing file', () async {
    final pid = await addPodcast('Show');
    final eid = await addEpisode(
      pid,
      title: 'Ep',
      status: DownloadStatus.downloaded,
      downloadPath: p.join(downloadsDir.path, 'gone.mp3'),
    );

    expect(await manager.prepareExportFile(eid), isNull);
  });
}
