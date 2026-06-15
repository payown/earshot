import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../data/chapter_platform_channel.dart';
import '../../data/chapter_service.dart';
import '../../domain/chapter.dart';
import 'player_providers.dart';

// ── Source 1: native audio-file chapters (ID3 CHAP / QuickTime tracks) ───────

final audioChaptersProvider = FutureProvider.family<List<Chapter>, String>((
  ref,
  audioUrl,
) {
  return ChapterPlatformChannel.getChapters(audioUrl);
});

// ── Source 2: Podcasting 2.0 external JSON ────────────────────────────────────

final chaptersForUrlProvider = FutureProvider.family<List<Chapter>, String>((
  ref,
  url,
) {
  return ref.watch(chapterServiceProvider).fetchChapters(url);
});

final currentChapterUrlProvider = StreamProvider<String?>((ref) {
  final episodeId =
      ref.watch(mediaItemProvider).asData?.value?.extras?['episodeId'] as int?;
  if (episodeId == null) return Stream.value(null);
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.episodes)..where((e) => e.id.equals(episodeId)))
      .watchSingleOrNull()
      .map((row) => row?.chapterUrl);
});

// ── Priority waterfall ────────────────────────────────────────────────────────
//
// 1. ID3 / QuickTime chapters baked into the audio file   ← highest priority
// 2. Podcasting 2.0 podcast:chapters JSON (linked in RSS)
// 3. Timestamps parsed from the episode show notes        ← fallback
//
// Each source is only tried if all higher-priority sources return empty.

final chaptersProvider = FutureProvider<List<Chapter>>((ref) async {
  final mediaItem = ref.watch(mediaItemProvider).asData?.value;

  // Source 1 — native audio file chapters.
  // Prefer the local file path for downloaded episodes so ChapterChannel
  // doesn't open a second network connection to the same URL that just_audio
  // is already streaming. AVURLAsset with a file:// URL reads from disk with
  // no network pressure.
  final downloadPath = mediaItem?.extras?['downloadPath'] as String?;
  final chapterLookupUrl = downloadPath != null
      ? Uri.file(downloadPath).toString()
      : mediaItem?.id;
  if (chapterLookupUrl != null) {
    final fromAudio = await ref.watch(
      audioChaptersProvider(chapterLookupUrl).future,
    );
    if (fromAudio.isNotEmpty) return fromAudio;
  }

  // Source 2 — Podcasting 2.0 JSON
  final chapterUrl = await ref.watch(currentChapterUrlProvider.future);
  if (chapterUrl != null && chapterUrl.isNotEmpty) {
    final fromJson = await ref.watch(chaptersForUrlProvider(chapterUrl).future);
    if (fromJson.isNotEmpty) return fromJson;
  }

  // Source 3 — description timestamps
  final description = await ref.watch(currentEpisodeDescriptionProvider.future);
  return ChapterService.parseDescriptionChapters(description);
});

// ── Derived providers ─────────────────────────────────────────────────────────

// Index of the chapter the current playback position falls within.
final currentChapterIndexProvider = Provider<int?>((ref) {
  final position = ref.watch(positionProvider).asData?.value;
  final chapters = ref.watch(chaptersProvider).asData?.value;
  if (position == null || chapters == null || chapters.isEmpty) return null;
  final seconds = position.inMilliseconds / 1000.0;
  int? result;
  for (var i = 0; i < chapters.length; i++) {
    if (seconds >= chapters[i].startTime) {
      result = i;
    } else {
      break;
    }
  }
  return result;
});

// In-memory map of episodeId → set of skipped chapter indices. Resets on restart.
class SkippedChaptersNotifier extends Notifier<Map<String, Set<int>>> {
  @override
  Map<String, Set<int>> build() => {};

  void toggle(String episodeId, int chapterIndex) {
    final next = Map<String, Set<int>>.from(state);
    final skipped = Set<int>.from(next[episodeId] ?? {});
    if (skipped.contains(chapterIndex)) {
      skipped.remove(chapterIndex);
    } else {
      skipped.add(chapterIndex);
    }
    next[episodeId] = skipped;
    state = next;
  }

  bool isSkipped(String episodeId, int chapterIndex) =>
      state[episodeId]?.contains(chapterIndex) ?? false;
}

final skippedChaptersProvider =
    NotifierProvider<SkippedChaptersNotifier, Map<String, Set<int>>>(
      SkippedChaptersNotifier.new,
    );
