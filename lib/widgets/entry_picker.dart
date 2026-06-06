import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/di.dart';
import '../core/theme.dart';
import '../data/repositories/entry_repository.dart';

/// Bottom-Sheet zum Suchen & Auswählen eines Eintrags (Notiz/Aufgabe).
/// Gibt den gewählten Eintrag zurück oder null bei Abbruch.
Future<EntryWithDetails?> showEntryPicker(
  BuildContext context,
  WidgetRef ref, {
  String? excludeId,
  String title = 'Verknüpfen mit…',
}) {
  return showModalBottomSheet<EntryWithDetails>(
    context: context,
    backgroundColor: MFColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _EntryPickerSheet(excludeId: excludeId, title: title),
  );
}

class _EntryPickerSheet extends ConsumerStatefulWidget {
  final String? excludeId;
  final String title;
  const _EntryPickerSheet({this.excludeId, required this.title});

  @override
  ConsumerState<_EntryPickerSheet> createState() => _EntryPickerSheetState();
}

class _EntryPickerSheetState extends ConsumerState<_EntryPickerSheet> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<EntryWithDetails> _results = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () => _search(q));
  }

  Future<void> _search(String q) async {
    setState(() => _loading = true);
    final results = await ref.read(entryRepositoryProvider).search(q);
    if (!mounted) return;
    setState(() {
      _results = results
          .where((e) => e.entry.id != widget.excludeId)
          .take(30)
          .toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold,
                  color: MFColors.textPrimary)),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            style: const TextStyle(fontSize: 14, color: MFColors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Suchen…',
              hintStyle: const TextStyle(color: MFColors.textMuted),
              prefixIcon: const Icon(Icons.search, size: 18, color: MFColors.textMuted),
              filled: true,
              fillColor: MFColors.bg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: MFColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: MFColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: MFColors.teal),
              ),
              isDense: true,
            ),
            onChanged: _onChanged,
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                        child: CircularProgressIndicator(color: MFColors.teal)),
                  )
                : _results.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: Text('Nichts gefunden',
                              style: TextStyle(color: MFColors.textMuted)),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: _results.length,
                        itemBuilder: (_, i) {
                          final item = _results[i];
                          final isTask = item.entry.type == 'task';
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              isTask ? Icons.task_alt_rounded : Icons.notes_rounded,
                              size: 18,
                              color: isTask ? MFColors.teal : MFColors.textMuted,
                            ),
                            title: Text(
                              item.entry.title ?? item.entry.body,
                              style: const TextStyle(
                                  fontSize: 14, color: MFColors.textPrimary),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => Navigator.of(context).pop(item),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
