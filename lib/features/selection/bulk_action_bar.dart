import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../domain/prop_type.dart';
import '../../services/openrouter_service.dart';
import 'selection_provider.dart';

const _storage = FlutterSecureStorage();

/// Untere Sammel-Toolbar — sichtbar im Auswahlmodus (Feed + Aufgaben).
class BulkActionBar extends ConsumerWidget {
  const BulkActionBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(selectedIdsProvider);
    if (!ref.watch(selectionModeProvider)) return const SizedBox.shrink();

    final repo = ref.read(entryRepositoryProvider);

    Future<void> forEach(Future<void> Function(String id) op) async {
      for (final id in ids.toList()) {
        try { await op(id); } catch (_) {}
      }
    }

    return Material(
      color: MFColors.surface,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: MFColors.border)),
          ),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.close, color: MFColors.textSecondary),
              tooltip: 'Auswahl beenden',
              onPressed: () => ref.clearSelection(),
            ),
            Text('${ids.length}',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold, color: MFColors.teal)),
            const Spacer(),
            // Primäraktionen
            _act(Icons.check_circle_outline, 'Status', () => _statusMenu(context, ref, forEach)),
            _act(Icons.label_outline, 'Tag', () => _tagSheet(context, ref, forEach)),
            _act(Icons.folder_outlined, 'Container', () => _containerSheet(context, ref, forEach)),
            // Überlauf
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: MFColors.textSecondary),
              color: MFColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: MFColors.border)),
              onSelected: (v) async {
                switch (v) {
                  case 'prop': await _propertySheet(context, ref, forEach); break;
                  case 'ai': await _bulkEnrich(context, ref, ids.toList()); break;
                  case 'task': await _createTasks(context, ref, ids.toList()); break;
                  case 'pin': await forEach((id) => repo.updateEntry(id, pinned: true)); ref.clearSelection(); break;
                  case 'unpin': await forEach((id) => repo.updateEntry(id, pinned: false)); ref.clearSelection(); break;
                  case 'delete': await _confirmDelete(context, ref, forEach); break;
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'prop', child: _MI(Icons.tune_rounded, 'Eigenschaft setzen')),
                PopupMenuItem(value: 'ai', child: _MI(Icons.auto_awesome_outlined, 'KI anreichern')),
                PopupMenuItem(value: 'task', child: _MI(Icons.add_task_rounded, 'Aufgabe erstellen')),
                PopupMenuItem(value: 'pin', child: _MI(Icons.push_pin_outlined, 'Anheften')),
                PopupMenuItem(value: 'unpin', child: _MI(Icons.push_pin_rounded, 'Anheften lösen')),
                PopupMenuItem(value: 'delete', child: _MI(Icons.delete_outline, 'Löschen', danger: true)),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  Widget _act(IconData icon, String tip, VoidCallback onTap) => IconButton(
        icon: Icon(icon, color: MFColors.textSecondary, size: 22),
        tooltip: tip,
        onPressed: onTap,
      );

  // ── Status ────────────────────────────────────────────────────────────────
  Future<void> _statusMenu(BuildContext context, WidgetRef ref,
      Future<void> Function(Future<void> Function(String)) forEach) async {
    final repo = ref.read(entryRepositoryProvider);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MFColors.surface,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        for (final s in const [('inbox', 'Inbox'), ('done', 'Erledigt'), ('archived', 'Archiviert')])
          ListTile(
            title: Text(s.$2, style: const TextStyle(color: MFColors.textPrimary)),
            onTap: () => Navigator.of(context).pop(s.$1),
          ),
      ]),
    );
    if (choice == null) return;
    await forEach((id) => repo.updateEntry(id, status: choice));
    ref.clearSelection();
  }

  // ── Tag ───────────────────────────────────────────────────────────────────
  Future<void> _tagSheet(BuildContext context, WidgetRef ref,
      Future<void> Function(Future<void> Function(String)) forEach) async {
    final all = await ref.read(tagDaoProvider).getAllTagNames();
    if (!context.mounted) return;
    final res = await showModalBottomSheet<(String, String)>(
      context: context,
      backgroundColor: MFColors.surface,
      isScrollControlled: true,
      builder: (_) => _TagBulkSheet(suggestions: all),
    );
    if (res == null) return;
    final repo = ref.read(entryRepositoryProvider);
    if (res.$1 == 'add') {
      await forEach((id) => repo.addTag(id, res.$2));
    } else {
      await forEach((id) => repo.removeTag(id, res.$2));
    }
    ref.clearSelection();
  }

  // ── Container ───────────────────────────────────────────────────────────────
  Future<void> _containerSheet(BuildContext context, WidgetRef ref,
      Future<void> Function(Future<void> Function(String)) forEach) async {
    final containers = await ref.read(containerDaoProvider).watchAll().first;
    if (!context.mounted) return;
    final cid = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MFColors.surface,
      builder: (_) => ListView(
        shrinkWrap: true,
        children: containers
            .map((c) => ListTile(
                  leading: const Icon(Icons.folder_outlined, color: MFColors.textMuted, size: 18),
                  title: Text(c.name, style: const TextStyle(color: MFColors.textPrimary)),
                  onTap: () => Navigator.of(context).pop(c.id),
                ))
            .toList(),
      ),
    );
    if (cid == null) return;
    final repo = ref.read(entryRepositoryProvider);
    final dao = ref.read(entryDaoProvider);
    await forEach((id) async {
      final cur = await dao.getContainerIds(id);
      if (!cur.contains(cid)) {
        await repo.updateEntry(id, containerIds: [...cur, cid]);
      }
    });
    ref.clearSelection();
  }

  // ── Properties (Ersetzen/Anhängen/Entfernen) ────────────────────────────────
  Future<void> _propertySheet(BuildContext context, WidgetRef ref,
      Future<void> Function(Future<void> Function(String)) forEach) async {
    final keys = await ref.read(propertyDaoProvider).getUniqueKeys();
    if (!context.mounted) return;
    final res = await showModalBottomSheet<_PropBulk>(
      context: context,
      backgroundColor: MFColors.surface,
      isScrollControlled: true,
      builder: (_) => _PropertyBulkSheet(existingKeys: keys),
    );
    if (res == null) return;
    final repo = ref.read(entryRepositoryProvider);
    if (res.mode == 'remove') {
      await forEach((id) => repo.removePropertyByKey(id, res.key));
    } else {
      await forEach((id) => repo.setPropertyByKey(
          id, res.key, res.value, res.type, append: res.mode == 'append'));
    }
    ref.clearSelection();
  }

  // ── KI-Anreicherung ──────────────────────────────────────────────────────────
  Future<void> _bulkEnrich(BuildContext context, WidgetRef ref, List<String> ids) async {
    final apiKey = await _storage.read(key: 'openrouter_api_key') ?? '';
    if (apiKey.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Kein OpenRouter-API-Key in den Einstellungen hinterlegt.')));
      }
      return;
    }
    final model = await _storage.read(key: 'openrouter_model') ?? '';
    final svc = OpenRouterService(
        apiKey: apiKey,
        model: model.isNotEmpty ? model : OpenRouterService.defaultModel);
    final repo = ref.read(entryRepositoryProvider);
    final tagDao = ref.read(tagDaoProvider);

    final progress = ValueNotifier<int>(0);
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.surface,
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (_, v, __) => Row(children: [
            const SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: MFColors.teal)),
            const SizedBox(width: 16),
            Text('KI: $v / ${ids.length}', style: const TextStyle(color: MFColors.textPrimary)),
          ]),
        ),
      ),
    );
    // Einmal vorab laden (nicht pro Eintrag) → der KI als bevorzugte Tags geben.
    final allTagNames = await tagDao.getAllTagNames();
    for (final id in ids) {
      try {
        final e = await repo.getById(id);
        if (e != null) {
          final r = await svc.enrichEntry(e.entry.body,
              existingTitle: e.entry.title, existingTags: allTagNames);
          if (r.title != null && (e.entry.title == null || e.entry.title!.isEmpty)) {
            await repo.updateEntry(id, title: r.title);
          }
          if (r.tags.isNotEmpty) {
            final existing = await tagDao.getTagNamesForEntry(id);
            await tagDao.setEntryTags(id, {...existing, ...r.tags}.toList());
          }
        }
      } catch (_) {}
      progress.value++;
    }
    progress.dispose();
    if (context.mounted) Navigator.of(context).pop(); // Dialog schließen
    ref.clearSelection();
  }

  // ── Aufgabe(n) erstellen ─────────────────────────────────────────────────────
  Future<void> _createTasks(BuildContext context, WidgetRef ref, List<String> ids) async {
    final repo = ref.read(entryRepositoryProvider);
    for (final id in ids) {
      try {
        final e = await repo.getById(id);
        if (e != null && e.entry.type != 'task') {
          await repo.createTask(
              title: e.entry.title ?? e.entry.body,
              sourceEntryId: id);
        }
      } catch (_) {}
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Aufgaben erstellt')));
    }
    ref.clearSelection();
  }

  // ── Löschen ───────────────────────────────────────────────────────────────
  Future<void> _confirmDelete(BuildContext context, WidgetRef ref,
      Future<void> Function(Future<void> Function(String)) forEach) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.surface,
        title: const Text('Löschen', style: TextStyle(color: MFColors.textPrimary)),
        content: const Text('Alle ausgewählten Einträge in den Papierkorb verschieben?',
            style: TextStyle(color: MFColors.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Abbrechen', style: TextStyle(color: MFColors.textMuted))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Löschen', style: TextStyle(color: Color(0xFFEF4444)))),
        ],
      ),
    );
    if (ok != true) return;
    await forEach((id) => ref.read(entryRepositoryProvider).deleteEntry(id));
    ref.clearSelection();
  }
}

class _MI extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool danger;
  const _MI(this.icon, this.label, {this.danger = false});
  @override
  Widget build(BuildContext context) {
    final c = danger ? const Color(0xFFEF4444) : MFColors.textPrimary;
    return Row(children: [
      Icon(icon, size: 16, color: danger ? const Color(0xFFEF4444) : MFColors.textSecondary),
      const SizedBox(width: 10),
      Text(label, style: TextStyle(color: c)),
    ]);
  }
}

// ── Tag-Sammel-Sheet ─────────────────────────────────────────────────────────
class _TagBulkSheet extends StatefulWidget {
  final List<String> suggestions;
  const _TagBulkSheet({required this.suggestions});
  @override
  State<_TagBulkSheet> createState() => _TagBulkSheetState();
}

class _TagBulkSheetState extends State<_TagBulkSheet> {
  final _ctrl = TextEditingController();
  String _mode = 'add';
  String _q = '';
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final filtered = widget.suggestions
        .where((s) => _q.isEmpty || s.toLowerCase().contains(_q.toLowerCase()))
        .take(20).toList();
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Tag (Sammelbearbeitung)', style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.bold, color: MFColors.textPrimary)),
          const SizedBox(height: 12),
          Row(children: [
            _modeChip('Hinzufügen', 'add'),
            const SizedBox(width: 6),
            _modeChip('Entfernen', 'remove'),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl, autofocus: true,
            style: const TextStyle(color: MFColors.textPrimary),
            decoration: const InputDecoration(hintText: 'Tag', filled: true,
                fillColor: MFColors.bg, border: OutlineInputBorder()),
            onChanged: (v) => setState(() => _q = v),
            onSubmitted: (v) => Navigator.of(context).pop((_mode, v.trim())),
          ),
          if (filtered.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: filtered.map((s) => GestureDetector(
              onTap: () => Navigator.of(context).pop((_mode, s)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: MFColors.bg,
                    borderRadius: BorderRadius.circular(8), border: Border.all(color: MFColors.border)),
                child: Text('#$s', style: const TextStyle(fontSize: 12, color: MFColors.teal)),
              ),
            )).toList()),
          ],
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: FilledButton(
            onPressed: () => Navigator.of(context).pop((_mode, _ctrl.text.trim())),
            style: FilledButton.styleFrom(backgroundColor: MFColors.teal, foregroundColor: MFColors.bg),
            child: const Text('Übernehmen'))),
        ]),
      ),
    );
  }
  Widget _modeChip(String label, String m) => GestureDetector(
    onTap: () => setState(() => _mode = m),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: _mode == m ? MFColors.tealBg : MFColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _mode == m ? MFColors.teal : MFColors.border)),
      child: Text(label, style: TextStyle(fontSize: 12,
          color: _mode == m ? MFColors.teal : MFColors.textSecondary)),
    ),
  );
}

// ── Property-Sammel-Sheet ─────────────────────────────────────────────────────
class _PropBulk {
  final String key; final String? value; final String type; final String mode;
  _PropBulk(this.key, this.value, this.type, this.mode);
}

class _PropertyBulkSheet extends StatefulWidget {
  final List<String> existingKeys;
  const _PropertyBulkSheet({required this.existingKeys});
  @override
  State<_PropertyBulkSheet> createState() => _PropertyBulkSheetState();
}

class _PropertyBulkSheetState extends State<_PropertyBulkSheet> {
  final _keyCtrl = TextEditingController();
  final _valCtrl = TextEditingController();
  String _mode = 'replace'; // replace | append | remove
  PropType _type = PropType.text;
  String _keyQ = '';
  @override
  void dispose() { _keyCtrl.dispose(); _valCtrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final keys = widget.existingKeys
        .where((k) => _keyQ.isEmpty || k.toLowerCase().contains(_keyQ.toLowerCase()))
        .take(8).toList();
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Eigenschaft (Sammelbearbeitung)', style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.bold, color: MFColors.textPrimary)),
          const SizedBox(height: 12),
          Wrap(spacing: 6, children: [
            _modeChip('Ersetzen', 'replace'),
            _modeChip('Anhängen', 'append'),
            _modeChip('Entfernen', 'remove'),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _keyCtrl, autofocus: true,
            style: const TextStyle(color: MFColors.textPrimary),
            decoration: const InputDecoration(hintText: 'Schlüssel', filled: true,
                fillColor: MFColors.bg, border: OutlineInputBorder()),
            onChanged: (v) => setState(() => _keyQ = v),
          ),
          if (keys.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: keys.map((k) => GestureDetector(
              onTap: () => setState(() { _keyCtrl.text = k; _keyQ = k; }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: MFColors.bg,
                    borderRadius: BorderRadius.circular(8), border: Border.all(color: MFColors.border)),
                child: Text(k, style: const TextStyle(fontSize: 12, color: MFColors.textSecondary)),
              ),
            )).toList()),
          ],
          if (_mode != 'remove') ...[
            const SizedBox(height: 10),
            TextField(
              controller: _valCtrl,
              style: const TextStyle(color: MFColors.textPrimary),
              decoration: const InputDecoration(hintText: 'Wert', filled: true,
                  fillColor: MFColors.bg, border: OutlineInputBorder()),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: FilledButton(
            onPressed: () {
              final key = _keyCtrl.text.trim();
              if (key.isEmpty) return;
              Navigator.of(context).pop(_PropBulk(
                  key, _mode == 'remove' ? null : _valCtrl.text.trim(), _type.value, _mode));
            },
            style: FilledButton.styleFrom(backgroundColor: MFColors.teal, foregroundColor: MFColors.bg),
            child: const Text('Übernehmen'))),
        ]),
      ),
    );
  }
  Widget _modeChip(String label, String m) => GestureDetector(
    onTap: () => setState(() => _mode = m),
    child: Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: _mode == m ? MFColors.tealBg : MFColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _mode == m ? MFColors.teal : MFColors.border)),
      child: Text(label, style: TextStyle(fontSize: 12,
          color: _mode == m ? MFColors.teal : MFColors.textSecondary)),
    ),
  );
}
