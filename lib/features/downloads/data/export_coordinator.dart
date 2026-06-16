import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio_export.dart';
import '../../../core/providers/core_providers.dart';
import '../presentation/providers/downloads_providers.dart';
import 'download_manager.dart';

/// Coordinates "Export audio file" for episodes that aren't downloaded yet.
///
/// The export action is always available. When the user taps it on an
/// undownloaded episode, the tap site (see `exportEpisodeAudio`) handles the
/// one-time cellular confirmation and then calls [requestExport]. This
/// coordinator starts a forced background download, waits for that episode's
/// terminal [DownloadOutcome], and — wherever the user has since navigated —
/// opens the share sheet on success or surfaces an error (with Retry) via the
/// app-wide ScaffoldMessenger.
///
/// Pending exports are held in memory only; they don't survive an app restart
/// (the downloaded file still lands in Downloads, so the user can export it
/// from there).
class ExportCoordinator {
  ExportCoordinator({
    required DownloadManager downloadManager,
    required GlobalKey<ScaffoldMessengerState> messengerKey,
    Future<void> Function(File file, String? subject)? share,
    void Function(String message)? announce,
  }) : _downloads = downloadManager,
       _messengerKey = messengerKey,
       _share = share ?? _defaultShare,
       _injectedAnnounce = announce {
    _sub = _downloads.downloadOutcomes.listen(_onOutcome);
  }

  final DownloadManager _downloads;
  final GlobalKey<ScaffoldMessengerState> _messengerKey;
  final Future<void> Function(File file, String? subject) _share;
  final void Function(String message)? _injectedAnnounce;
  late final StreamSubscription<DownloadOutcome> _sub;

  // episodeId -> share subject, for downloads in flight for export.
  final Map<int, String?> _pending = {};

  // episodeId -> one-shot "still downloading" reminder timer.
  final Map<int, Timer> _progressTimers = {};

  /// How long an export download may run before the user gets a verbal
  /// "still downloading" nudge (the initial SnackBar auto-hides before this).
  static const _stillDownloadingAfter = Duration(seconds: 5);

  static const _unavailableMessage =
      "This episode can't be downloaded — the audio file may no longer be "
      'available.';

  static Future<void> _defaultShare(File file, String? subject) =>
      shareExportedAudioFile(file, subject: subject);

  /// Starts (or joins) a download for [episodeId] and exports it when ready.
  Future<void> requestExport(int episodeId, {String? subject}) async {
    final result = await _downloads.downloadEpisode(episodeId, force: true);
    switch (result) {
      case DownloadStartResult.alreadyDownloaded:
        await _shareNow(episodeId, subject);
      case DownloadStartResult.started:
      case DownloadStartResult.alreadyDownloading:
        _pending[episodeId] = subject;
        _show('Downloading for export…', announce: 'Downloading for export');
        // A slow download outlives the initial SnackBar; reassure the user it's
        // still working if it's been a while and hasn't finished.
        _progressTimers[episodeId]?.cancel();
        _progressTimers[episodeId] = Timer(_stillDownloadingAfter, () {
          _progressTimers.remove(episodeId);
          if (_pending.containsKey(episodeId)) _announce('Still downloading');
        });
      case DownloadStartResult.notFound:
        _show(_unavailableMessage);
      case DownloadStartResult.failed:
      case DownloadStartResult.skippedNoWifi:
        // skippedNoWifi shouldn't happen with force; treat as a failure.
        _showRetry(episodeId, subject);
    }
  }

  void _onOutcome(DownloadOutcome outcome) {
    if (!_pending.containsKey(outcome.episodeId)) return;
    final subject = _pending.remove(outcome.episodeId);
    _progressTimers.remove(outcome.episodeId)?.cancel();
    if (outcome.success) {
      unawaited(_shareNow(outcome.episodeId, subject));
      return;
    }
    switch (outcome.reason ?? DownloadFailureReason.networkOrUnknown) {
      case DownloadFailureReason.unavailable:
        _show(_unavailableMessage);
      case DownloadFailureReason.networkOrUnknown:
        _showRetry(outcome.episodeId, subject);
    }
  }

  Future<void> _shareNow(int episodeId, String? subject) async {
    final file = await _downloads.prepareExportFile(episodeId);
    if (file == null) {
      _show(_unavailableMessage);
      return;
    }
    await _share(file, subject);
  }

  // SnackBars aren't reliably announced by VoiceOver on iOS, so every message
  // is also pushed through the screen reader explicitly. The coordinator has no
  // BuildContext of its own; it borrows the messenger's context for the View.
  void _announce(String message) {
    if (_injectedAnnounce != null) {
      _injectedAnnounce(message);
      return;
    }
    final ctx = _messengerKey.currentState?.context;
    if (ctx == null) return;
    SemanticsService.sendAnnouncement(View.of(ctx), message, TextDirection.ltr);
  }

  void _show(String message, {String? announce}) {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    _announce(announce ?? message);
  }

  void _showRetry(int episodeId, String? subject) {
    // The "Try again" SnackBar action is a sighted convenience. The durable,
    // time-limit-free retry (WCAG 2.2.1) is the always-present "Export audio
    // file" action on the episode, which the announcement points AT users to.
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text("Export failed — download didn't complete."),
          duration: const Duration(seconds: 15),
          action: SnackBarAction(
            label: 'Try again',
            onPressed: () => requestExport(episodeId, subject: subject),
          ),
        ),
      );
    _announce(
      "Export failed — download didn't complete. Try exporting the episode "
      'again.',
    );
  }

  void dispose() {
    for (final timer in _progressTimers.values) {
      timer.cancel();
    }
    _progressTimers.clear();
    unawaited(_sub.cancel());
  }
}

final exportCoordinatorProvider = Provider<ExportCoordinator>((ref) {
  final coordinator = ExportCoordinator(
    downloadManager: ref.watch(downloadManagerProvider),
    messengerKey: ref.watch(scaffoldMessengerKeyProvider),
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
