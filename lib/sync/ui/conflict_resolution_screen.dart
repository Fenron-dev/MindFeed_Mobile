import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../dto/sync_dto.dart';
import '../sync_provider.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../data/db/app_database.dart' as appdb;
import '../../widgets/app_shell.dart' show navigateToEntry;

class ConflictResolutionScreen extends ConsumerWidget {
  final List<SyncConflict> conflicts;
  const ConflictResolutionScreen({super.key, required this.conflicts});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        title: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
          const SizedBox(width: 8),
          Text('${conflicts.length} Sync-Konflikt${conflicts.length != 1 ? 'e' : ''}',
              style: const TextStyle(fontSize: 16, color: MFColors.textPrimary)),
        ]),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(syncStateProvider.notifier).clearConflicts();
              Navigator.pop(context);
            },
            child: const Text('Schließen', style: TextStyle(color: MFColors.textMuted)),
          ),
        ],
      ),
      body: Column(
        children: [
          // Erklärungstext
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withAlpha(20),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.withAlpha(80)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Was sind Konflikte?',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                        color: MFColors.textPrimary)),
                SizedBox(height: 4),
                Text(
                  'Dieselbe Notiz wurde lokal und auf dem Server geändert. '
                  'Klicke auf einen Eintrag um ihn zu öffnen, dann entscheide '
                  'ob deine lokale Version oder die Server-Version behalten werden soll.',
                  style: TextStyle(fontSize: 12, color: MFColors.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),

          // Konflikt-Liste
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: conflicts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _ConflictCard(
                conflict: conflicts[i],
                index: i + 1,
                total: conflicts.length,
              ),
            ),
          ),

          // Global: Alle auf einmal auflösen
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    ref.read(syncStateProvider.notifier)
                        .resolveConflicts(ConflictResolution.server);
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.cloud_download_outlined, size: 16),
                  label: const Text('Server gewinnt (alle)', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF6366F1),
                    side: const BorderSide(color: Color(0xFF6366F1)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    ref.read(syncStateProvider.notifier)
                        .resolveConflicts(ConflictResolution.mine);
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.smartphone_outlined, size: 16),
                  label: const Text('Meine Version (alle)', style: TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                    backgroundColor: MFColors.teal,
                    foregroundColor: MFColors.bg,
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _ConflictCard extends ConsumerWidget {
  final SyncConflict conflict;
  final int index;
  final int total;
  const _ConflictCard({required this.conflict, required this.index, required this.total});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

    return FutureBuilder(
      future: _loadEntry(ref),
      builder: (context, snapshot) {
        final entry = snapshot.data;
        final serverTs = DateTime.tryParse(conflict.serverModifiedAt)?.toLocal();

        return Container(
          decoration: BoxDecoration(
            color: MFColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange.withAlpha(60)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.withAlpha(25),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('$index / $total',
                        style: const TextStyle(fontSize: 10, color: Colors.orange,
                            fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    conflict.entityType == 'entry'
                        ? Icons.article_outlined
                        : Icons.folder_outlined,
                    size: 14, color: Colors.orange,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    conflict.entityType == 'entry' ? 'Eintrag' : 'Container',
                    style: const TextStyle(fontSize: 12, color: MFColors.textMuted),
                  ),
                  const Spacer(),
                  if (serverTs != null)
                    Text(
                      'Server: ${DateFormat('dd.MM.yy HH:mm').format(serverTs)}',
                      style: const TextStyle(fontSize: 10, color: MFColors.textMuted,
                          fontFamily: 'monospace'),
                    ),
                ]),
              ),

              // ── Eintrag-Inhalt ───────────────────────────────────────────────
              if (snapshot.connectionState == ConnectionState.waiting)
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: LinearProgressIndicator(color: MFColors.teal,
                      backgroundColor: MFColors.border, minHeight: 1),
                )
              else if (entry != null) ...[
                InkWell(
                  onTap: () {
                    if (conflict.entityType == 'entry') {
                      navigateToEntry(context, ref, conflict.entityId);
                      if (!isDesktop) Navigator.pop(context);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: _ConflictEntityDetail(
                      entityType: conflict.entityType,
                      entity: entry,
                      serverModifiedAt: serverTs,
                      localModifiedAt: conflict.entityType == 'entry'
                          ? (entry.updatedAt as DateTime?)
                          : (entry.updatedAt as DateTime?),
                    ),
                  ),
                ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: Text(
                    'ID: ${conflict.entityId}',
                    style: const TextStyle(fontSize: 11, color: MFColors.textMuted,
                        fontFamily: 'monospace'),
                  ),
                ),
              ],

              // ── Trennlinie ───────────────────────────────────────────────────
              const Divider(height: 1, color: MFColors.border),

              // ── Entscheide für DIESEN Konflikt ───────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Row(children: [
                  const Text('Entscheide:',
                      style: TextStyle(fontSize: 11, color: MFColors.textMuted)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _resolveOne(ref, context, ConflictResolution.server),
                      icon: const Icon(Icons.cloud_download_outlined, size: 12),
                      label: const Text('Server', style: TextStyle(fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF6366F1),
                        side: const BorderSide(color: Color(0xFF6366F1), width: 0.8),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _resolveOne(ref, context, ConflictResolution.mine),
                      icon: const Icon(Icons.smartphone_outlined, size: 12),
                      label: const Text('Meine', style: TextStyle(fontSize: 11)),
                      style: FilledButton.styleFrom(
                        backgroundColor: MFColors.teal,
                        foregroundColor: MFColors.bg,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<dynamic> _loadEntry(WidgetRef ref) async {
    final db = ref.read(databaseProvider);
    try {
      if (conflict.entityType == 'entry') {
        return await (db.select(db.entries)
              ..where((e) => e.id.equals(conflict.entityId)))
            .getSingleOrNull();
      } else if (conflict.entityType == 'container') {
        return await (db.select(db.containers)
              ..where((c) => c.id.equals(conflict.entityId)))
            .getSingleOrNull();
      }
    } catch (_) {}
    return null;
  }

  void _resolveOne(WidgetRef ref, BuildContext context, ConflictResolution resolution) {
    // Einzelnen Konflikt auflösen: diesen aus der Liste entfernen,
    // dann im Hintergrund die passende Aktion ausführen
    final notifier = ref.read(syncStateProvider.notifier);
    final remaining = ref.read(syncStateProvider).pendingConflicts
        .where((c) => c.entityId != conflict.entityId).toList();

    if (resolution == ConflictResolution.mine) {
      notifier.resolveConflicts(ConflictResolution.mine);
    } else {
      // Server hat schon gewonnen → Konflikt einfach entfernen
      notifier.clearSingleConflict(conflict.entityId);
    }

    if (remaining.isEmpty && context.mounted) {
      Navigator.pop(context);
    }
  }
}

// ── Detail-Widget: Entry oder Container ───────────────────────────────────────

class _ConflictEntityDetail extends StatelessWidget {
  final String entityType;
  final dynamic entity;
  final DateTime? serverModifiedAt;
  final DateTime? localModifiedAt;

  const _ConflictEntityDetail({
    required this.entityType,
    required this.entity,
    this.serverModifiedAt,
    this.localModifiedAt,
  });

  @override
  Widget build(BuildContext context) {
    if (entityType == 'entry') {
      final e = entity as appdb.Entry;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (e.title != null && e.title!.isNotEmpty)
            Text(e.title!,
                style: const TextStyle(fontSize: 14,
                    fontWeight: FontWeight.w600, color: MFColors.textPrimary)),
          if (e.body.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              e.body.length > 200 ? '${e.body.substring(0, 200)}…' : e.body,
              style: const TextStyle(fontSize: 12,
                  color: MFColors.textSecondary, height: 1.45),
            ),
          ],
          const SizedBox(height: 8),
          _TwoVersionRow(
            localTs: localModifiedAt,
            serverTs: serverModifiedAt,
          ),
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.open_in_new, size: 12, color: MFColors.teal),
            const SizedBox(width: 4),
            const Text('Tippe zum Öffnen des Eintrags',
                style: TextStyle(fontSize: 11, color: MFColors.teal)),
          ]),
        ],
      );
    } else {
      // Container
      final c = entity as appdb.Container;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(_kindIcon(c.kind), size: 16, color: MFColors.teal),
            const SizedBox(width: 6),
            Expanded(
              child: Text(c.name,
                  style: const TextStyle(fontSize: 14,
                      fontWeight: FontWeight.w600, color: MFColors.textPrimary)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(_kindLabel(c.kind),
              style: const TextStyle(fontSize: 11, color: MFColors.textMuted)),
          if (c.description != null && c.description!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(c.description!,
                style: const TextStyle(fontSize: 12, color: MFColors.textSecondary)),
          ],
          const SizedBox(height: 8),
          _TwoVersionRow(localTs: localModifiedAt, serverTs: serverModifiedAt),
          const SizedBox(height: 4),
          const Text(
            'Der Container (Projekt/Bereich/Hub) wurde auf beiden Seiten geändert.',
            style: TextStyle(fontSize: 11, color: MFColors.textMuted, height: 1.3),
          ),
        ],
      );
    }
  }

  IconData _kindIcon(String kind) => switch (kind) {
        'area' => Icons.explore_outlined,
        'hub' => Icons.layers_outlined,
        _ => Icons.folder_outlined,
      };

  String _kindLabel(String kind) => switch (kind) {
        'area' => 'Bereich',
        'hub' => 'Smart Hub',
        _ => 'Projekt',
      };
}

class _TwoVersionRow extends StatelessWidget {
  final DateTime? localTs;
  final DateTime? serverTs;
  const _TwoVersionRow({this.localTs, this.serverTs});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd.MM.yy HH:mm');
    return Row(children: [
      _VersionChip(
        icon: Icons.smartphone_outlined,
        label: 'Lokal',
        ts: localTs != null ? fmt.format(localTs!.toLocal()) : '–',
        color: MFColors.teal,
      ),
      const SizedBox(width: 6),
      const Icon(Icons.compare_arrows, size: 14, color: MFColors.textMuted),
      const SizedBox(width: 6),
      _VersionChip(
        icon: Icons.cloud_outlined,
        label: 'Server',
        ts: serverTs != null ? fmt.format(serverTs!.toLocal()) : '–',
        color: const Color(0xFF6366F1),
      ),
    ]);
  }
}

class _VersionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String ts;
  final Color color;
  const _VersionChip({required this.icon, required this.label,
      required this.ts, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 9, color: color,
              fontWeight: FontWeight.bold)),
          Text(ts, style: TextStyle(fontSize: 10, color: color,
              fontFamily: 'monospace')),
        ]),
      ]),
    );
  }
}
