import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/app_settings.dart';
import 'client/sync_api_client.dart';
import 'sync_provider.dart';

class SyncScheduler with WidgetsBindingObserver {
  final Ref _ref;
  Timer? _timer;
  Timer? _notifyTimer; // Poll ob Server Sync auslösen möchte
  DateTime? _lastNotifyCheck;

  SyncScheduler(this._ref) {
    WidgetsBinding.instance.addObserver(this);
    _setupTimer();
    _setupNotifyPoll();
    Future.microtask(_onAppStart);
  }

  Future<void> _onAppStart() async {
    // Server automatisch starten wenn Rolle = Server
    if (AppSettings.getSyncRole() == SyncRole.server && AppSettings.getSyncEnabled()) {
      final server = _ref.read(syncServerProvider);
      if (!server.isRunning) await server.start();
      await _ref.read(mdnsServiceProvider).startAdvertising(
        AppSettings.getDeviceId(),
        AppSettings.getDeviceName(),
      );
    }
    // Sync beim App-Start ausführen (falls konfiguriert)
    if (AppSettings.getSyncOnAppStart() && AppSettings.getSyncEnabled()) {
      await _doSync();
    }
  }

  void _setupTimer() {
    _timer?.cancel();
    if (!AppSettings.getSyncAutoEnabled() || !AppSettings.getSyncEnabled()) return;
    final minutes = AppSettings.getSyncAutoIntervalMinutes();
    _timer = Timer.periodic(Duration(minutes: minutes), (_) => _doSync());
  }

  void reconfigure() {
    _setupTimer();
    _setupNotifyPoll();
  }

  void _setupNotifyPoll() {
    _notifyTimer?.cancel();
    // Nur als Client und wenn Sync aktiviert → alle 30s Server-Notification pollen
    if (AppSettings.getSyncRole() != SyncRole.client) return;
    if (!AppSettings.getSyncEnabled()) return;
    _notifyTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkServerNotify());
  }

  Future<void> _checkServerNotify() async {
    final serverUrl = AppSettings.getSyncServerUrl();
    if (serverUrl == null) return;
    try {
      final client = SyncApiClient(serverUrl);
      final requestedAt = await client.getServerSyncNotification();
      if (requestedAt == null) return;
      if (_lastNotifyCheck == null || requestedAt.isAfter(_lastNotifyCheck!)) {
        _lastNotifyCheck = DateTime.now();
        await _doSync();
      }
    } catch (_) {}
  }

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
    _notifyTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
