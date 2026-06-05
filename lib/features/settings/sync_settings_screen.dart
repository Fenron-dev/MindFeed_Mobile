import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/theme.dart';
import '../../sync/dto/sync_dto.dart';
import '../../sync/sync_provider.dart';
import '../../sync/server/sync_server.dart';
import '../../sync/ui/pairing_flow_screen.dart';
import '../../sync/ui/conflict_resolution_screen.dart';
import '../../services/app_settings.dart';

class SyncSettingsScreen extends ConsumerStatefulWidget {
  const SyncSettingsScreen({super.key});

  @override
  ConsumerState<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends ConsumerState<SyncSettingsScreen> {
  late SyncRole _role;
  late bool _enabled;
  late bool _autoEnabled;
  late int _intervalMinutes;
  late bool _onAppStart;
  late bool _onResume;
  late bool _attachmentsEnabled;
  late SyncAttachmentsDirection _attachmentsDirection;
  final _deviceNameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _role = AppSettings.getSyncRole();
    _enabled = AppSettings.getSyncEnabled();
    _autoEnabled = AppSettings.getSyncAutoEnabled();
    _intervalMinutes = AppSettings.getSyncAutoIntervalMinutes();
    _onAppStart = AppSettings.getSyncOnAppStart();
    _onResume = AppSettings.getSyncOnResume();
    _attachmentsEnabled = AppSettings.getSyncAttachments();
    _attachmentsDirection = AppSettings.getSyncAttachmentsDirection();
    _deviceNameCtrl.text = AppSettings.getDeviceName();
  }

  @override
  void dispose() {
    _deviceNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveAndReconfigure() async {
    await AppSettings.saveDeviceName(_deviceNameCtrl.text.trim().isNotEmpty
        ? _deviceNameCtrl.text.trim()
        : 'MindFeed Mobile');
    await AppSettings.saveSyncRole(_role);
    await AppSettings.saveSyncEnabled(_enabled);
    await AppSettings.saveSyncAutoEnabled(_autoEnabled);
    await AppSettings.saveSyncAutoIntervalMinutes(_intervalMinutes);
    await AppSettings.saveSyncOnAppStart(_onAppStart);
    await AppSettings.saveSyncOnResume(_onResume);
    await AppSettings.saveSyncAttachments(_attachmentsEnabled);
    await AppSettings.saveSyncAttachmentsDirection(_attachmentsDirection);

    ref.read(syncStateProvider.notifier).setEnabled(_enabled);
    ref.read(syncSchedulerProvider).reconfigure();

    // Start/stop embedded server based on role
    final server = ref.read(syncServerProvider);
    if (_role == SyncRole.server && _enabled) {
      await server.start();
      await ref.read(mdnsServiceProvider).startAdvertising(
            AppSettings.getDeviceId(),
            AppSettings.getDeviceName(),
          );
    } else {
      await server.stop();
      await ref.read(mdnsServiceProvider).stopAdvertising();
    }
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncStateProvider);
    final serverUrl = AppSettings.getSyncServerUrl();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync & Geräte'),
        actions: [
          TextButton(
            onPressed: () async {
              await _saveAndReconfigure();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Status ──────────────────────────────────────────────────────────
          _SectionHeader('Status'),
          _StatusTile(state: syncState),
          if (syncState.pendingConflicts.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
              title: Text('${syncState.pendingConflicts.length} Konflikte vorhanden'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ConflictResolutionScreen(
                    conflicts: syncState.pendingConflicts,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (_role == SyncRole.server) ...[
            // Server: verbundene Clients + Sync-Trigger
            _ConnectedClientsWidget(),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () async {
                final server = ref.read(syncServerProvider);
                server.syncNotifyRequestedAt = DateTime.now().toUtc();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Sync-Ping an alle Clients gesendet'),
                  behavior: SnackBarBehavior.floating,
                ));
              },
              icon: const Icon(Icons.broadcast_on_personal, size: 16),
              label: const Text('Sync bei allen Clients auslösen'),
              style: FilledButton.styleFrom(
                backgroundColor: MFColors.teal,
                foregroundColor: MFColors.bg,
              ),
            ),
          ] else ...[
            FilledButton.icon(
              onPressed: syncState.status == SyncStatus.syncing
                  ? null
                  : () => ref.read(syncStateProvider.notifier).triggerSync(),
              icon: const Icon(Icons.sync),
              label: const Text('Jetzt synchronisieren'),
            ),
          ],

          const SizedBox(height: 24),

          // ── Gerät ────────────────────────────────────────────────────────────
          _SectionHeader('Dieses Gerät'),
          TextField(
            controller: _deviceNameCtrl,
            decoration: const InputDecoration(
              labelText: 'Gerätename',
              hintText: 'z.B. Dennis iPhone',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          _RolePicker(
            value: _role,
            onChanged: (r) => setState(() => _role = r),
          ),

          const SizedBox(height: 24),

          // ── Verbindung ───────────────────────────────────────────────────────
          _SectionHeader('Verbindung'),
          SwitchListTile(
            title: const Text('Sync aktiviert'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          if (_role == SyncRole.server) ...[
            ListTile(
              leading: const Icon(Icons.qr_code),
              title: const Text('Gerät koppeln (QR / Code)'),
              subtitle: Text('Port: ${kSyncPort}'),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PairingFlowScreen()),
              ),
            ),
            _IpTile(),
          ] else ...[
            if (serverUrl != null) ...[
              // Bereits verbunden
              ListTile(
                leading: const Icon(Icons.check_circle_outline, color: Colors.green),
                title: const Text('Verbunden'),
                subtitle: Text(serverUrl, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
              ),
              ListTile(
                leading: const Icon(Icons.link_off_outlined),
                title: const Text('Anderen Server koppeln'),
                subtitle: const Text('Verbindung ersetzen'),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () async {
                  await Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const PairingFlowScreen()));
                  setState(() {});
                },
              ),
            ] else ...[
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Mit Server verbinden'),
                subtitle: const Text('Noch nicht verbunden'),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () async {
                  await Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const PairingFlowScreen()));
                  setState(() {});
                },
              ),
            ],
          ],

          const SizedBox(height: 24),

          // ── Auto-Sync ────────────────────────────────────────────────────────
          _SectionHeader('Automatischer Sync'),
          SwitchListTile(
            title: const Text('Auto-Sync'),
            subtitle: const Text('Regelmäßig im Hintergrund synchronisieren'),
            value: _autoEnabled,
            onChanged: (v) => setState(() => _autoEnabled = v),
          ),
          if (_autoEnabled)
            ListTile(
              title: const Text('Intervall'),
              trailing: DropdownButton<int>(
                value: _intervalMinutes,
                items: [1, 5, 10, 15, 30, 60]
                    .map((m) => DropdownMenuItem(
                          value: m,
                          child: Text('$m Min'),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _intervalMinutes = v);
                },
              ),
            ),
          SwitchListTile(
            title: const Text('Sync beim App-Start'),
            value: _onAppStart,
            onChanged: (v) => setState(() => _onAppStart = v),
          ),
          SwitchListTile(
            title: const Text('Sync nach App-Wechsel'),
            value: _onResume,
            onChanged: (v) => setState(() => _onResume = v),
          ),

          const SizedBox(height: 24),

          // ── Anhänge ──────────────────────────────────────────────────────────
          _SectionHeader('Anhang-Sync'),
          SwitchListTile(
            title: const Text('Anhänge synchronisieren'),
            subtitle: const Text('Bilder und Audio-Dateien einbeziehen'),
            value: _attachmentsEnabled,
            onChanged: (v) => setState(() => _attachmentsEnabled = v),
          ),
          if (_attachmentsEnabled)
            ListTile(
              title: const Text('Richtung'),
              trailing: DropdownButton<SyncAttachmentsDirection>(
                value: _attachmentsDirection,
                items: const [
                  DropdownMenuItem(
                    value: SyncAttachmentsDirection.both,
                    child: Text('Beide Richtungen'),
                  ),
                  DropdownMenuItem(
                    value: SyncAttachmentsDirection.downloadOnly,
                    child: Text('Nur herunterladen'),
                  ),
                  DropdownMenuItem(
                    value: SyncAttachmentsDirection.uploadOnly,
                    child: Text('Nur hochladen'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _attachmentsDirection = v);
                },
              ),
            ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
            letterSpacing: 1,
          ),
        ),
      );
}

class _StatusTile extends StatelessWidget {
  final SyncState state;
  const _StatusTile({required this.state});

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (state.status) {
      SyncStatus.idle => (Icons.check_circle_outline, Colors.grey, 'Bereit'),
      SyncStatus.syncing =>
        (Icons.sync, Theme.of(context).colorScheme.primary, 'Synchronisiert…'),
      SyncStatus.success => (Icons.check_circle, Colors.green, 'Erfolgreich'),
      SyncStatus.error => (Icons.error_outline, Colors.red, state.message ?? 'Fehler'),
      SyncStatus.disabled => (Icons.sync_disabled, Colors.grey, 'Deaktiviert'),
      SyncStatus.notConfigured => (Icons.link_off, Colors.grey, 'Nicht konfiguriert'),
    };

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(label),
      subtitle: state.lastSyncAt != null
          ? Text(
              'Letzter Sync: ${DateFormat('dd.MM.yy HH:mm').format(state.lastSyncAt!.toLocal())}',
              style: const TextStyle(fontSize: 12),
            )
          : const Text('Noch nicht synchronisiert',
              style: TextStyle(fontSize: 12)),
    );
  }
}

class _RolePicker extends StatelessWidget {
  final SyncRole value;
  final ValueChanged<SyncRole> onChanged;
  const _RolePicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 4),
          child: Text('Rolle', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ),
        Row(
          children: [
            Expanded(
              child: _RoleChip(
                label: 'Server',
                subtitle: 'Haupt-DB, empfängt Verbindungen',
                icon: Icons.dns_outlined,
                selected: value == SyncRole.server,
                onTap: () => onChanged(SyncRole.server),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _RoleChip(
                label: 'Client',
                subtitle: 'Verbindet sich mit Server',
                icon: Icons.phone_android,
                selected: value == SyncRole.client,
                onTap: () => onChanged(SyncRole.client),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RoleChip extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _RoleChip({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? cs.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20,
                color: selected ? cs.onPrimaryContainer : Colors.grey),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: selected ? cs.onPrimaryContainer : null)),
            Text(subtitle,
                style: TextStyle(
                    fontSize: 11,
                    color: selected
                        ? cs.onPrimaryContainer.withValues(alpha: 0.75)
                        : Colors.grey)),
          ],
        ),
      ),
    );
  }
}

class _IpTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _getLocalIp(),
      builder: (ctx, snap) {
        final ip = snap.data ?? '…';
        return ListTile(
          leading: const Icon(Icons.lan_outlined),
          title: Text('Eigene IP: $ip:${kSyncPort}'),
          subtitle: const Text('Andere Geräte können sich damit verbinden'),
          trailing: IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              // Copy to clipboard handled by OS
            },
          ),
        );
      },
    );
  }

  Future<String> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return 'Unbekannt';
  }
}

// ── Verbundene Clients Widget ─────────────────────────────────────────────────

class _ConnectedClientsWidget extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(syncServerProvider);
    final clients = server.connectedClients;
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));

    if (clients.isEmpty) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.devices_other, color: Colors.grey),
        title: Text('Noch keine Clients gekoppelt'),
        subtitle: Text('Clients müssen sich einmalig über den QR-Code koppeln'),
      );
    }

    final onlineCount = server.onlineClientCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text('${clients.length} gekoppelte${clients.length != 1 ? '' : 'r'} Client${clients.length != 1 ? 's' : ''}',
              style: const TextStyle(fontSize: 12, color: MFColors.textMuted)),
          if (onlineCount > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withAlpha(25),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: const Color(0xFF10B981).withAlpha(80)),
              ),
              child: Text('$onlineCount online',
                  style: const TextStyle(fontSize: 10, color: Color(0xFF10B981),
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ]),
        const SizedBox(height: 6),
        ...clients.map((c) {
          final isOnline = (server.clientLastSeen[c.deviceId] ?? DateTime(2000))
              .isAfter(cutoff);
          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: MFColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isOnline
                    ? const Color(0xFF10B981).withAlpha(60)
                    : MFColors.border,
              ),
            ),
            child: Row(children: [
              // Online-Indikator
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOnline ? const Color(0xFF10B981) : MFColors.border,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.deviceName.isNotEmpty ? c.deviceName : 'Unbekanntes Gerät',
                      style: const TextStyle(fontSize: 13, color: MFColors.textPrimary,
                          fontWeight: FontWeight.w500)),
                  Text(c.remoteIp,
                      style: const TextStyle(fontSize: 10, fontFamily: 'monospace',
                          color: MFColors.textMuted)),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(isOnline ? 'Online' : 'Offline',
                    style: TextStyle(fontSize: 11,
                        color: isOnline ? const Color(0xFF10B981) : MFColors.textMuted,
                        fontWeight: FontWeight.w500)),
                if (server.clientLastSeen[c.deviceId] != null)
                  Text(_timeAgo(server.clientLastSeen[c.deviceId]!),
                      style: const TextStyle(fontSize: 10, color: MFColors.textMuted)),
              ]),
            ]),
          );
        }),
      ],
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'gerade eben';
    if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} Min';
    if (diff.inHours < 24) return 'vor ${diff.inHours} Std';
    return 'vor ${diff.inDays} Tagen';
  }
}
