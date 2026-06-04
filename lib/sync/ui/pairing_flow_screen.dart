import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../dto/sync_dto.dart';
import '../sync_provider.dart';
import '../client/sync_api_client.dart';
import '../../services/app_settings.dart';

class PairingFlowScreen extends ConsumerStatefulWidget {
  const PairingFlowScreen({super.key});

  @override
  ConsumerState<PairingFlowScreen> createState() => _PairingFlowScreenState();
}

class _PairingFlowScreenState extends ConsumerState<PairingFlowScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gerät koppeln'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.search), text: 'Suchen'),
            Tab(icon: Icon(Icons.qr_code_scanner), text: 'QR scannen'),
            Tab(icon: Icon(Icons.qr_code), text: 'QR zeigen'),
            Tab(icon: Icon(Icons.edit), text: 'Manuell'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _DiscoveryTab(),
          _QrScanTab(),
          _QrDisplayTab(),
          _ManualTab(),
        ],
      ),
    );
  }
}

// ── Tab 1: mDNS auto-discovery ───────────────────────────────────────────────

class _DiscoveryTab extends ConsumerStatefulWidget {
  const _DiscoveryTab();

  @override
  ConsumerState<_DiscoveryTab> createState() => _DiscoveryTabState();
}

class _DiscoveryTabState extends ConsumerState<_DiscoveryTab> {
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    setState(() => _scanning = true);
    await ref.read(mdnsServiceProvider).startDiscovery();
    setState(() => _scanning = false);
  }

  @override
  Widget build(BuildContext context) {
    final peersAsync = ref.watch(discoveredPeersProvider);
    return peersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Fehler: $e')),
      data: (peers) {
        if (peers.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_scanning) const CircularProgressIndicator(),
                const SizedBox(height: 16),
                const Text('Suche nach MindFeed-Servern im Netzwerk…'),
                const SizedBox(height: 8),
                TextButton(onPressed: _startScan, child: const Text('Erneut suchen')),
              ],
            ),
          );
        }
        return ListView.builder(
          itemCount: peers.length,
          itemBuilder: (ctx, i) {
            final peer = peers[i];
            return ListTile(
              leading: const Icon(Icons.devices),
              title: Text(peer.deviceName),
              subtitle: Text('${peer.host}:${peer.port}'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () => _connectToPeer(peer),
            );
          },
        );
      },
    );
  }

  Future<void> _connectToPeer(SyncPeer peer) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _EnterCodeScreen(peer: peer),
      ),
    );
  }
}

// ── Tab 2: QR scan ───────────────────────────────────────────────────────────

class _QrScanTab extends ConsumerStatefulWidget {
  const _QrScanTab();

  @override
  ConsumerState<_QrScanTab> createState() => _QrScanTabState();
}

class _QrScanTabState extends ConsumerState<_QrScanTab> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    // MobileScanner verwendet die Gerätekamera — auf Desktop via Webcam,
    // aber mobile_scanner benötigt auf macOS ggf. spezifische Entitlements.
    // Fallback: manuelles Code-Eingabe-Feld wenn Kamera nicht verfügbar.
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      return _DesktopQrFallback(onPair: _pairWith);
    }

    return MobileScanner(
      onDetect: (capture) {
        if (_handled) return;
        final barcode = capture.barcodes.firstOrNull;
        if (barcode?.rawValue == null) return;
        final raw = barcode!.rawValue!;
        // Expected: "mindfeed://pair?url=http://host:port&code=123456"
        final uri = Uri.tryParse(raw);
        if (uri == null || uri.scheme != 'mindfeed') return;
        final serverUrl = uri.queryParameters['url'];
        final code = uri.queryParameters['code'];
        if (serverUrl == null || code == null) return;
        _handled = true;
        _pairWith(serverUrl, code);
      },
    );
  }

  Future<void> _pairWith(String serverUrl, String code) async {
    final client = SyncApiClient(serverUrl);
    try {
      final result = await client.claimPairingCode(
          code, AppSettings.getDeviceName());
      await AppSettings.saveSyncServerUrl(serverUrl);
      await AppSettings.saveSyncEnabled(true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Verbunden mit ${result.serverName}'),
        ));
        Navigator.pop(context, true);
      }
    } catch (e) {
      setState(() => _handled = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e')),
        );
      }
    }
  }
}

// ── Tab 3: QR display (Server-Modus) ─────────────────────────────────────────

class _QrDisplayTab extends ConsumerStatefulWidget {
  const _QrDisplayTab();

  @override
  ConsumerState<_QrDisplayTab> createState() => _QrDisplayTabState();
}

class _QrDisplayTabState extends ConsumerState<_QrDisplayTab> {
  String? _code;
  String? _localIp;
  bool _serverStarting = false;

  @override
  void initState() {
    super.initState();
    _startServerAndGenerate();
  }

  Future<void> _startServerAndGenerate() async {
    setState(() => _serverStarting = true);
    // Eigene IP ermitteln
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            _localIp = addr.address;
            break;
          }
        }
        if (_localIp != null) break;
      }
    } catch (_) {}

    // Server starten (falls noch nicht läuft)
    final server = ref.read(syncServerProvider);
    if (!server.isRunning) await server.start();

    _generate();
    if (mounted) setState(() => _serverStarting = false);
  }

  void _generate() {
    final server = ref.read(syncServerProvider);
    setState(() => _code = server.generatePairingCode());
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;

    if (_serverStarting || code == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Server wird gestartet…', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    // QR-Daten: eigene IP:Port + Pairing-Code
    final ip = _localIp ?? '127.0.0.1';
    final qrData = 'mindfeed://pair?url=http://$ip:8766&code=$code';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Zeige diesen QR-Code dem anderen Gerät',
              style: TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Server: http://$ip:8766',
              style: const TextStyle(fontSize: 12, color: Colors.grey, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 16),
            // Weißer Hintergrund damit QR-Code in Dark Mode sichtbar ist
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                data: qrData,
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const Text('Oder Code manuell eingeben',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  Text(
                    code,
                    style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 8),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Gültig für 5 Minuten',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _generate,
              icon: const Icon(Icons.refresh),
              label: const Text('Neuen Code generieren'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tab 4: Manual entry ───────────────────────────────────────────────────────

class _ManualTab extends ConsumerStatefulWidget {
  const _ManualTab();

  @override
  ConsumerState<_ManualTab> createState() => _ManualTabState();
}

class _ManualTabState extends ConsumerState<_ManualTab> {
  final _urlCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = AppSettings.getSyncServerUrl();
    if (existing != null) _urlCtrl.text = existing;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = SyncApiClient(_urlCtrl.text.trim());
      final result = await client.claimPairingCode(
          _codeCtrl.text.trim(), AppSettings.getDeviceName());
      await AppSettings.saveSyncServerUrl(_urlCtrl.text.trim());
      await AppSettings.saveSyncEnabled(true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Verbunden mit ${result.serverName}'),
        ));
        Navigator.pop(context, true);
      }
    } on SyncException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Server-URL', style: TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              hintText: 'http://192.168.1.100:8766',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 16),
          const Text('Pairing-Code (6 Stellen)',
              style: TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          TextField(
            controller: _codeCtrl,
            decoration: const InputDecoration(
              hintText: '123456',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _loading ? null : _connect,
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Verbinden'),
          ),
        ],
      ),
    );
  }
}

// ── Enter-Code dialog (for mDNS-discovered peers) ────────────────────────────

class _EnterCodeScreen extends ConsumerStatefulWidget {
  final SyncPeer peer;
  const _EnterCodeScreen({required this.peer});

  @override
  ConsumerState<_EnterCodeScreen> createState() => _EnterCodeScreenState();
}

class _EnterCodeScreenState extends ConsumerState<_EnterCodeScreen> {
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = SyncApiClient(widget.peer.baseUrl);
      final result = await client.claimPairingCode(
          _codeCtrl.text.trim(), AppSettings.getDeviceName());
      await AppSettings.saveSyncServerUrl(widget.peer.baseUrl);
      await AppSettings.saveSyncEnabled(true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Verbunden mit ${result.serverName}'),
        ));
        Navigator.pop(context, true);
        Navigator.pop(context, true);
      }
    } on SyncException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.peer.deviceName)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Verbinde mit: ${widget.peer.baseUrl}',
                style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 24),
            const Text('Pairing-Code (vom Server)',
                style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            TextField(
              controller: _codeCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '123456',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _loading ? null : _connect,
              child: _loading
                  ? const SizedBox(
                      height: 20, width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Koppeln'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Desktop-Fallback für QR-Scan (URL + Code manuell eingeben) ───────────────

class _DesktopQrFallback extends StatefulWidget {
  final Future<void> Function(String url, String code) onPair;
  const _DesktopQrFallback({required this.onPair});

  @override
  State<_DesktopQrFallback> createState() => _DesktopQrFallbackState();
}

class _DesktopQrFallbackState extends State<_DesktopQrFallback> {
  final _urlCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() { _loading = true; _error = null; });
    try {
      await widget.onPair(_urlCtrl.text.trim(), _codeCtrl.text.trim());
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.qr_code_scanner, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          const Text(
            'QR-Code-Scan ist auf dem Desktop nicht verfügbar.\nBitte gib die Server-URL und den Pairing-Code manuell ein.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'Server-URL',
              hintText: 'http://192.168.1.100:8766',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _codeCtrl,
            decoration: const InputDecoration(
              labelText: 'Pairing-Code (6 Stellen)',
              hintText: '123456',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _loading ? null : _connect,
            child: _loading
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Verbinden'),
          ),
        ],
      ),
    );
  }
}
