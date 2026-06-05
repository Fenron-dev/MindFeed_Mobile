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
    try {
      // mDNS: Wenn gespeicherte Server-URL nicht mehr stimmt (Netzwerkwechsel),
      // aktuelle IP via mDNS-Discovery nachschlagen und URL aktualisieren.
      await _refreshServerUrlViaMdns();

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
    } catch (e) {
      // Sicherheitsnetz: verhindert dass der Status dauerhaft auf 'syncing' bleibt
      state = state.copyWith(status: SyncStatus.error, message: e.toString());
      return SyncResult.failed(e.toString());
    }
  }

  /// Versucht via mDNS-Discovery die aktuelle Server-IP zu ermitteln.
  /// Aktualisiert AppSettings.syncServerUrl, wenn ein bekannter Server
  /// mit neuer IP entdeckt wurde (z.B. nach Netzwerkwechsel).
  Future<void> _refreshServerUrlViaMdns() async {
    final storedUrl = AppSettings.getSyncServerUrl();
    if (storedUrl == null) return;

    try {
      final mdns = ref.read(mdnsServiceProvider);
      await mdns.startDiscovery();
      // Kurz warten, damit mDNS-Antworten eingehen können
      await Future.delayed(const Duration(milliseconds: 800));
      final peers = mdns.currentPeers;
      if (peers.isEmpty) return;

      // Gespeicherten Port aus URL extrahieren
      final storedUri = Uri.tryParse(storedUrl);
      if (storedUri == null) return;

      // Erster gefundener Peer → URL aktualisieren falls IP anders
      final peer = peers.first;
      final newUrl = 'http://${peer.host}:${peer.port}';
      if (newUrl != storedUrl) {
        await AppSettings.saveSyncServerUrl(newUrl);
      }
    } catch (_) {
      // mDNS-Fehler ignorieren — sync läuft mit gespeicherter URL weiter
    }
  }

  void setEnabled(bool enabled) {
    AppSettings.saveSyncEnabled(enabled);
    state = state.copyWith(
        status: enabled ? SyncStatus.idle : SyncStatus.disabled);
  }

  void clearConflicts() => state = state.copyWith(pendingConflicts: []);

  void clearSingleConflict(String entityId) {
    final remaining = state.pendingConflicts
        .where((c) => c.entityId != entityId)
        .toList();
    state = state.copyWith(pendingConflicts: remaining);
  }

  /// Alle Konflikte auf einmal auflösen.
  Future<void> resolveConflicts(ConflictResolution resolution) async {
    await _resolve(resolution, state.pendingConflicts);
    state = state.copyWith(pendingConflicts: []);
  }

  /// Einen einzelnen Konflikt auflösen (Detailansicht).
  Future<void> resolveSingleConflict(
      String entityId, ConflictResolution resolution) async {
    final target =
        state.pendingConflicts.where((c) => c.entityId == entityId).toList();
    if (target.isEmpty) return;
    await _resolve(resolution, target);
    state = state.copyWith(
      pendingConflicts: state.pendingConflicts
          .where((c) => c.entityId != entityId)
          .toList(),
    );
  }

  Future<void> _resolve(
      ConflictResolution resolution, List<SyncConflict> conflicts) async {
    if (conflicts.isEmpty) return;
    final service = ref.read(syncServiceProvider);
    if (resolution == ConflictResolution.mine) {
      await service.resolveConflictsMine(conflicts);
    } else {
      await service.resolveConflictsServer(conflicts);
    }
  }
}

enum ConflictResolution { server, mine }

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
  // getInstance() gibt immer dieselbe Instanz zurück → pairingCodes bleiben erhalten
  return SyncServer.getInstance(
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
