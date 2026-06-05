import 'dart:async';
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
  late final TextEditingController _deviceNameCtrl;

  @override
  void initState() {
    super.initState();
    // Default zu QR-Scan (Tab 1) – die häufigste Client-Aktion auf Mobile
    _tabs = TabController(length: 4, vsync: this, initialIndex: 1);
    _deviceNameCtrl = TextEditingController(text: AppSettings.getDeviceName());
  }

  @override
  void dispose() {
    _tabs.dispose();
    _deviceNameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Keyboard-Handling erfolgt manuell in den Tabs
      resizeToAvoidBottomInset: false,
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
      body: Column(
        children: [
          // ── Gerätename-Eingabe (für alle Tabs sichtbar) ───────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _deviceNameCtrl,
              decoration: const InputDecoration(
                labelText: 'Mein Gerätename',
                hintText: 'z.B. Dennis iPhone',
                border: OutlineInputBorder(),
                isDense: true,
                prefixIcon: Icon(Icons.phone_android, size: 18),
              ),
              onChanged: (v) {
                if (v.trim().isNotEmpty) {
                  AppSettings.saveDeviceName(v.trim()); // fire-and-forget
                }
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [
                _DiscoveryTab(),
                _QrScanTab(),
                _QrDisplayTab(),
                _ManualTab(),
              ],
            ),
          ),
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
    if (!mounted) return;
    setState(() => _scanning = true);
    await ref.read(mdnsServiceProvider).startDiscovery();
    if (!mounted) return;
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
      MaterialPageRoute(builder: (_) => _EnterCodeScreen(peer: peer)),
    );
  }
}

// ── Tab 2: QR scan ───────────────────────────────────────────────────────────

// Kein Riverpod nötig — nutzt nur AppSettings
class _QrScanTab extends StatefulWidget {
  const _QrScanTab();

  @override
  State<_QrScanTab> createState() => _QrScanTabState();
}

class _QrScanTabState extends State<_QrScanTab> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
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
      // _handled nicht zurücksetzen — verhindert Endlos-Retry wenn Scanner
      // den QR erneut erkennt. "Erneut"-Button gibt Kontrolle zurück.
      if (mounted) {
        final msg = e is TimeoutException
            ? 'Server nicht erreichbar (Timeout). Prüfe Netzwerk und Firewall (Port 8766).'
            : 'Fehler: $e';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'Erneut',
            onPressed: () => setState(() => _handled = false),
          ),
        ));
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
  String? _startError;

  @override
  void initState() {
    super.initState();
    _startServerAndGenerate();
  }

  Future<void> _startServerAndGenerate() async {
    if (mounted) setState(() { _serverStarting = true; _startError = null; });
    try {
      // LAN-IP ermitteln (192.168.x, 10.x, 172.16-31.x bevorzugen)
      try {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        String? anyNonLoopback;
        outer:
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (addr.isLoopback) continue;
            final h = addr.address;
            anyNonLoopback ??= h;
            if (h.startsWith('192.168.') ||
                h.startsWith('10.') ||
                RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(h)) {
              _localIp = h;
              break outer;
            }
          }
        }
        _localIp ??= anyNonLoopback;
      } catch (_) {}

      // Server starten (falls noch nicht läuft)
      final server = ref.read(syncServerProvider);
      if (!server.isRunning) await server.start();

      _generate();
    } catch (e) {
      if (mounted) setState(() => _startError = e.toString());
    } finally {
      if (mounted) setState(() => _serverStarting = false);
    }
  }

  void _generate() {
    if (!mounted) return;
    final server = ref.read(syncServerProvider);
    setState(() => _code = server.generatePairingCode());
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;

    if (_startError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 12),
              const Text('Server konnte nicht gestartet werden',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(_startError!, style: const TextStyle(color: Colors.grey, fontSize: 12),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _startServerAndGenerate,
                icon: const Icon(Icons.refresh),
                label: const Text('Erneut versuchen'),
              ),
            ],
          ),
        ),
      );
    }

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

    final ip = _localIp ?? '127.0.0.1';
    final qrData = 'mindfeed://pair?url=http://$ip:8766&code=$code';

    return Center(
      child: SingleChildScrollView(
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
                        fontSize: 32, fontWeight: FontWeight.bold, letterSpacing: 8),
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

// Kein Riverpod nötig — nutzt nur AppSettings
class _ManualTab extends StatefulWidget {
  const _ManualTab();

  @override
  State<_ManualTab> createState() => _ManualTabState();
}

class _ManualTabState extends State<_ManualTab> {
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
    if (!mounted) return;
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
    } on TimeoutException {
      if (mounted) {
        setState(() => _error =
            'Server nicht erreichbar (Timeout). Prüfe IP-Adresse, Port und ob die Firewall Port 8766 zulässt.');
      }
    } on SyncException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keyboard-Inset manuell addieren, da resizeToAvoidBottomInset: false
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottomInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
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
    if (!mounted) return;
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
    } on TimeoutException {
      if (mounted) {
        setState(() => _error =
            'Server nicht erreichbar (Timeout). Prüfe Netzwerk und Firewall (Port 8766).');
      }
    } on SyncException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text(widget.peer.deviceName)),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottomInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
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
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      await widget.onPair(_urlCtrl.text.trim(), _codeCtrl.text.trim());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(32, 32, 32, 32 + bottomInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
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
