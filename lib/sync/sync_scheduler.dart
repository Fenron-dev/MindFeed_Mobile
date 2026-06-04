import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/app_settings.dart';
import 'sync_provider.dart';

class SyncScheduler with WidgetsBindingObserver {
  final Ref _ref;
  Timer? _timer;

  SyncScheduler(this._ref) {
    WidgetsBinding.instance.addObserver(this);
    _setupTimer();
    if (AppSettings.getSyncOnAppStart() && AppSettings.getSyncEnabled()) {
      Future.microtask(_doSync);
    }
  }

  void _setupTimer() {
    _timer?.cancel();
    if (!AppSettings.getSyncAutoEnabled() || !AppSettings.getSyncEnabled()) return;
    final minutes = AppSettings.getSyncAutoIntervalMinutes();
    _timer = Timer.periodic(Duration(minutes: minutes), (_) => _doSync());
  }

  void reconfigure() => _setupTimer();

  Future<void> _doSync() async {
    if (!AppSettings.getSyncEnabled()) return;
    await _ref.read(syncStateProvider.notifier).triggerSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        AppSettings.getSyncOnResume() &&
        AppSettings.getSyncEnabled()) {
      _doSync();
    }
  }

  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
