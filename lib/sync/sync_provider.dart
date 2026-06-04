import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/di.dart';
import '../services/app_settings.dart';
import 'dto/sync_dto.dart';
import 'client/sync_service.dart';
import 'server/sync_server.dart';
import 'discovery/mdns_service.dart';
import 'sync_scheduler.dart';

// ── SyncStatus provider ────────────────────────────────────────────────────

class SyncStateNotifier extends Notifier<SyncState> {
  @override
  SyncState build() => SyncState(
        status: AppSettings.getSyncEnabled()
            ? SyncStatus.idle
            : SyncStatus.disabled,
        lastSyncAt: AppSettings.getLastSyncAt(),
      );

  Future<SyncResult> triggerSync() async {
    state = state.copyWith(status: SyncStatus.syncing, message: null);
    final service = ref.read(syncServiceProvider);
    final result = await service.sync();
    if (result.success) {
      state = state.copyWith(
        status: SyncStatus.success,
        lastSyncAt: result.completedAt,
        pendingConflicts: result.conflicts,
        message: result.conflicts.isNotEmpty
            ? '${result.conflicts.length} Konflikte gefunden'
            : null,
      );
    } else {
      state = state.copyWith(status: SyncStatus.error, message: result.error);
    }
    return result;
  }

  void setEnabled(bool enabled) {
    AppSettings.saveSyncEnabled(enabled);
    state = state.copyWith(
        status: enabled ? SyncStatus.idle : SyncStatus.disabled);
  }

  void clearConflicts() => state = state.copyWith(pendingConflicts: []);
}

final syncStateProvider =
    NotifierProvider<SyncStateNotifier, SyncState>(SyncStateNotifier.new);

// ── SyncService provider ───────────────────────────────────────────────────

final syncServiceProvider = Provider<SyncService>((ref) {
  final db = ref.watch(databaseProvider);
  final entryDao = ref.watch(entryDaoProvider);
  final containerDao = ref.watch(containerDaoProvider);
  return SyncService(db: db, entryDao: entryDao, containerDao: containerDao);
});

// ── SyncServer provider ────────────────────────────────────────────────────

final syncServerProvider = Provider<SyncServer>((ref) {
  final db = ref.watch(databaseProvider);
  return SyncServer(
    db: db,
    deviceId: AppSettings.getDeviceId(),
    deviceName: AppSettings.getDeviceName(),
  );
});

// ── MdnsService provider ───────────────────────────────────────────────────

final mdnsServiceProvider = Provider<MdnsService>((ref) {
  final svc = MdnsService();
  ref.onDispose(svc.dispose);
  return svc;
});

final discoveredPeersProvider = StreamProvider<List<SyncPeer>>((ref) {
  return ref.watch(mdnsServiceProvider).peersStream;
});

// ── SyncScheduler provider ─────────────────────────────────────────────────

final syncSchedulerProvider = Provider<SyncScheduler>((ref) {
  final scheduler = SyncScheduler(ref);
  ref.onDispose(scheduler.dispose);
  return scheduler;
});
