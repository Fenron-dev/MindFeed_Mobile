import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme.dart';

/// Vollbild-QR-/Barcode-Scanner. Liefert den dekodierten Roh-String via
/// `Navigator.pop(context, value)` zurück (oder `null` bei Abbruch).
///
/// Auf Desktop-Plattformen (macOS/Windows/Linux) ist die Kamera über
/// mobile_scanner unzuverlässig — dort wird ein manuelles Eingabefeld als
/// Fallback gezeigt (Code-Inhalt direkt einfügen).
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (raw == null) return;
    _handled = true;
    Navigator.pop(context, raw);
  }

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('QR-Code scannen',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        actions: _isDesktop
            ? null
            : [
                IconButton(
                  icon: const Icon(Icons.flash_on_rounded, color: Colors.white),
                  tooltip: 'Taschenlampe',
                  onPressed: () => _controller.toggleTorch(),
                ),
                IconButton(
                  icon: const Icon(Icons.cameraswitch_rounded,
                      color: Colors.white),
                  tooltip: 'Kamera wechseln',
                  onPressed: () => _controller.switchCamera(),
                ),
              ],
      ),
      body: _isDesktop ? _buildDesktopFallback() : _buildScanner(),
    );
  }

  Widget _buildScanner() {
    return Stack(
      alignment: Alignment.center,
      children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        // Scan-Rahmen
        Container(
          width: 240,
          height: 240,
          decoration: BoxDecoration(
            border: Border.all(color: MFColors.teal, width: 3),
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        const Positioned(
          bottom: 60,
          left: 24,
          right: 24,
          child: Text(
            'QR-Code im Rahmen positionieren',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopFallback() {
    final ctrl = TextEditingController();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.qr_code_2_rounded,
                size: 64, color: MFColors.textMuted),
            const SizedBox(height: 16),
            const Text(
              'Kamera-Scan ist auf dem Desktop nicht verfügbar.\n'
              'Inhalt des QR-Codes (z.B. Link) hier einfügen:',
              textAlign: TextAlign.center,
              style: TextStyle(color: MFColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(color: MFColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'https://…',
                hintStyle: const TextStyle(color: MFColors.textMuted),
                filled: true,
                fillColor: MFColors.surfaceAlt,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: MFColors.border),
                ),
              ),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
              },
            ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: MFColors.teal),
              onPressed: () {
                final v = ctrl.text.trim();
                if (v.isNotEmpty) Navigator.pop(context, v);
              },
              child: const Text('Übernehmen'),
            ),
          ],
        ),
      ),
    );
  }
}
