import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../features/settings/data/app_settings_repository.dart';
import '../../features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'core_providers.dart';

final _log = Logger('AutoRefresh');

const _kAutoRefreshThreshold = Duration(minutes: 15);

final autoRefreshProvider = NotifierProvider<_AutoRefreshNotifier, void>(
  _AutoRefreshNotifier.new,
);

class _AutoRefreshNotifier extends Notifier<void> with WidgetsBindingObserver {
  bool _refreshInFlight = false;

  @override
  void build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(this));
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshIfStale());
    }
  }

  Future<void> _refresh() async {
    if (_refreshInFlight) return;
    _refreshInFlight = true;
    try {
      final settings = _settings();
      await ref.read(podcastRepositoryProvider).refreshAllFeeds();
      await settings.setLastAutoRefreshAt(DateTime.now().toUtc());
    } catch (e, st) {
      _log.warning('Auto-refresh failed', e, st);
    } finally {
      _refreshInFlight = false;
    }
  }

  Future<void> _refreshIfStale() async {
    if (_refreshInFlight) return;
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

  AppSettingsRepository _settings() =>
      AppSettingsRepositoryImpl(database: ref.read(appDatabaseProvider));
}
