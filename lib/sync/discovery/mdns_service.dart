import 'dart:async';
import 'package:bonsoir/bonsoir.dart';
import '../dto/sync_dto.dart';
import '../server/sync_server.dart';

const _kServiceType = '_mindfeed._tcp';

class MdnsService {
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  final _peersController = StreamController<List<SyncPeer>>.broadcast();
  final _peers = <String, SyncPeer>{};

  Stream<List<SyncPeer>> get peersStream => _peersController.stream;
  List<SyncPeer> get currentPeers => List.unmodifiable(_peers.values);

  // ── Server: advertise own presence via mDNS ────────────────────────────────

  Future<void> startAdvertising(String deviceId, String deviceName) async {
    await stopAdvertising();
    final service = BonsoirService(
      name: deviceName,
      type: _kServiceType,
      port: kSyncPort,
      attributes: {'deviceId': deviceId},
    );
    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.initialize();
    await _broadcast!.start();
  }

  Future<void> stopAdvertising() async {
    await _broadcast?.stop();
    _broadcast = null;
  }

  // ── Client: discover peers on the local network ────────────────────────────

  Future<void> startDiscovery() async {
    await stopDiscovery();
    _discovery = BonsoirDiscovery(type: _kServiceType);
    await _discovery!.initialize();

    _discovery!.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          // Trigger resolution
          _discovery!.serviceResolver.resolveService(event.service);
        case BonsoirDiscoveryServiceResolvedEvent():
          _handleResolved(event.service);
        case BonsoirDiscoveryServiceUpdatedEvent():
          _handleResolved(event.service);
        case BonsoirDiscoveryServiceLostEvent():
          final deviceId = event.service.attributes['deviceId'] ?? event.service.name;
          _peers.remove(deviceId);
          _peersController.add(currentPeers);
        default:
          break;
      }
    });

    await _discovery!.start();
  }

  void _handleResolved(BonsoirService svc) {
    final host = svc.hostAddresses.firstOrNull ?? '';
    if (host.isEmpty) return;
    final deviceId = svc.attributes['deviceId'] ?? svc.name;
    final peer = SyncPeer(
      deviceId: deviceId,
      deviceName: svc.name,
      host: host,
      port: svc.port,
    );
    _peers[deviceId] = peer;
    _peersController.add(currentPeers);
  }

  Future<void> stopDiscovery() async {
    await _discovery?.stop();
    _discovery = null;
    _peers.clear();
  }

  void dispose() {
    stopAdvertising();
    stopDiscovery();
    _peersController.close();
  }
}
