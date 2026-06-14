import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/prop_type.dart';
import '../../services/enrichment/api_field_catalog.dart';
import '../../services/enrichment/api_field_prefs.dart';
import '../../services/enrichment/metadata_record.dart';

/// Ein vom Nutzer bestätigtes Feld, das in den Eintrag geschrieben wird.
class ResolvedField {
  /// Property-Key (kanonisch, z.B. `anilist_studio`, oder das Label bei
  /// eigenen Feldern).
  final String storageKey;
  final String value;

  /// Legacy-Property-Typ für das EntryProperties-Schema (`string`/`number`/`url`).
  final String propType;

  const ResolvedField(this.storageKey, this.value, this.propType);
}

/// Interner, editierbarer Zustand einer Zeile.
class _Row {
  final String label;
  final String storageKey;
  final PropType type;
  final String propType;
  final bool isImage;
  bool enabled;
  final TextEditingController ctrl;

  _Row({
    required this.label,
    required this.storageKey,
    required this.type,
    required this.propType,
    required this.isImage,
    required this.enabled,
    required String value,
  }) : ctrl = TextEditingController(text: value);
}

/// Review-Sheet vor dem finalen Speichern: zeigt die abgerufenen Felder,
/// erlaubt An-/Abwählen, Überschreiben und Ergänzen eigener Felder. Liefert die
/// bestätigte Auswahl zurück oder `null`, wenn abgebrochen wurde.
class FieldImportSheet extends StatefulWidget {
  final MetadataRecord record;
  final ApiFieldPrefs prefs;

  const FieldImportSheet({super.key, required this.record, required this.prefs});

  /// Öffnet das Sheet. Gibt die bestätigten Felder zurück, oder `null` bei
  /// Abbruch.
  static Future<List<ResolvedField>?> show(
    BuildContext context, {
    required MetadataRecord record,
    required ApiFieldPrefs prefs,
  }) {
    return showModalBottomSheet<List<ResolvedField>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MFColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FieldImportSheet(record: record, prefs: prefs),
    );
  }

  @override
  State<FieldImportSheet> createState() => _FieldImportSheetState();
}

class _FieldImportSheetState extends State<FieldImportSheet> {
  late final List<_Row> _rows;

  @override
  void initState() {
    super.initState();
    _rows = _buildRows();
  }

  List<_Row> _buildRows() {
    final rows = <_Row>[];
    final source = widget.record.source;
    final usedKeys = <String>{};
    // 1) Im Katalog beschriebene Felder in Katalog-Reihenfolge.
    for (final def in ApiFieldCatalog.fieldsFor(source)) {
      final raw = widget.record.fields[def.key];
      if (raw == null || '$raw'.isEmpty) continue;
      usedKeys.add(def.key);
      rows.add(_Row(
        label: def.label,
        storageKey: def.storageKey,
        type: def.type,
        propType: def.legacyPropType,
        isImage: def.type == PropType.url &&
            (def.key == 'image' || def.label.toLowerCase().contains('cover')),
        enabled: widget.prefs.isEnabled(source, def.key),
        value: _stringify(raw),
      ));
    }
    // 2) Übrige Felder, die der Record liefert, aber (noch) nicht im Katalog
    //    stehen — als generische Textfelder, standardmäßig aus.
    widget.record.fields.forEach((key, raw) {
      if (usedKeys.contains(key) || raw == null || '$raw'.isEmpty) return;
      rows.add(_Row(
        label: key,
        storageKey: key,
        type: PropType.text,
        propType: 'string',
        isImage: false,
        enabled: false,
        value: _stringify(raw),
      ));
    });
    return rows;
  }

  static String _stringify(dynamic v) {
    if (v is List) return v.join(', ');
    return '$v';
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.ctrl.dispose();
    }
    super.dispose();
  }

  void _addCustomField() async {
    final labelCtrl = TextEditingController();
    final valueCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.surface,
        title: const Text('Feld hinzufügen',
            style: TextStyle(color: MFColors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelCtrl,
              style: const TextStyle(color: MFColors.textPrimary),
              decoration: const InputDecoration(labelText: 'Bezeichnung'),
            ),
            TextField(
              controller: valueCtrl,
              style: const TextStyle(color: MFColors.textPrimary),
              decoration: const InputDecoration(labelText: 'Wert'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Hinzufügen')),
        ],
      ),
    );
    if (ok == true && labelCtrl.text.trim().isNotEmpty) {
      setState(() {
        _rows.add(_Row(
          label: labelCtrl.text.trim(),
          storageKey: labelCtrl.text.trim(),
          type: PropType.text,
          propType: 'string',
          isImage: false,
          enabled: true,
          value: valueCtrl.text.trim(),
        ));
      });
    }
  }

  void _confirm() {
    final result = <ResolvedField>[];
    for (final r in _rows) {
      if (!r.enabled) continue;
      final v = r.ctrl.text.trim();
      if (v.isEmpty) continue;
      result.add(ResolvedField(r.storageKey, v, r.propType));
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scrollCtrl) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: MFColors.borderLight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  const Icon(Icons.download_rounded,
                      color: MFColors.teal, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Inhalte von ${widget.record.source.label}',
                      style: const TextStyle(
                        color: MFColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Wähle, was übernommen wird. Werte sind editierbar.',
                  style: TextStyle(color: MFColors.textMuted, fontSize: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _rows.length,
                itemBuilder: (_, i) => _buildRowTile(_rows[i]),
              ),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildRowTile(_Row r) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: MFColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MFColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: r.enabled,
                activeColor: MFColors.teal,
                onChanged: (v) => setState(() => r.enabled = v ?? false),
              ),
              Expanded(
                child: Text(r.label,
                    style: const TextStyle(
                        color: MFColors.textPrimary,
                        fontWeight: FontWeight.w500)),
              ),
            ],
          ),
          if (r.isImage && r.ctrl.text.startsWith('http'))
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 8, right: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  r.ctrl.text,
                  height: 120,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: TextField(
              controller: r.ctrl,
              enabled: r.enabled,
              maxLines: r.type == PropType.text ? null : 1,
              style: TextStyle(
                color: r.enabled ? MFColors.textSecondary : MFColors.textMuted,
                fontSize: 13,
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              onChanged: (_) {
                if (r.isImage) setState(() {});
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 8, 16, 12 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: MFColors.surface,
        border: Border(top: BorderSide(color: MFColors.border)),
      ),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _addCustomField,
            icon: const Icon(Icons.add_rounded, size: 18, color: MFColors.teal),
            label: const Text('Feld',
                style: TextStyle(color: MFColors.teal)),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Abbrechen',
                style: TextStyle(color: MFColors.textMuted)),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _confirm,
            style: FilledButton.styleFrom(backgroundColor: MFColors.teal),
            child: const Text('Übernehmen'),
          ),
        ],
      ),
    );
  }
}
