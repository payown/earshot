import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../features/settings/data/app_settings_repository.dart';
import '../../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'core_providers.dart';

final _log = Logger('AutoRefresh');

const _kAutoRefreshThreshold = Duration(minutes: 15);

final autoRefreshProvider = NotifierProvider<_AutoRefreshNotifier, bool>(
  _AutoRefreshNotifier.new,
);

class _AutoRefreshNotifier extends Notifier<bool> with WidgetsBindingObserver {
  // Stored so concurrent callers (e.g. pull-to-refresh during the on-open
  // auto-refresh) join the in-flight operation rather than returning early.
  Future<void>? _inFlight;

  @override
  bool build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(this));
    unawaited(_refresh());
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.resumed) {
      unawaited(_refreshIfStale());
    }
  }

  Future<void> _refresh() {
    _inFlight ??= _doRefresh().whenComplete(() => _inFlight = null);
    return _inFlight!;
  }

  Future<void> _doRefresh() async {
    try {
      state = true;
      final settings = _settings();
      await ref.read(podcastRepositoryProvider).refreshAllFeeds();
      await settings.setLastAutoRefreshAt(DateTime.now().toUtc());
    } catch (e, st) {
      _log.warning('Auto-refresh failed', e, st);
    } finally {
      state = false;
    }
  }

  Future<void> _refreshIfStale() async {
    if (state) return;
    try {
      final settings = _settings();
      final last = await settings.getLastAutoRefreshAt();
      final now = DateTime.now().toUtc();
      if (last == null || now.difference(last) >= _kAutoRefreshThreshold) {
        await _refresh();
      }
    } catch (e, st) {
      _log.warning('Auto-refresh (resume) failed', e, st);
    }
  }

  Future<void> refresh() => _refresh();

  AppSettingsRepository _settings() =>
      AppSettingsRepositoryImpl(database: ref.read(appDatabaseProvider));
}
