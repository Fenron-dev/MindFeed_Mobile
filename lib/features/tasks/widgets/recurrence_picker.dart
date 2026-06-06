import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../domain/recurrence_calculator.dart';

/// Bottom Sheet zum Auswählen einer Wiederholungsregel.
Future<RecurrenceRule?> showRecurrencePicker(
    BuildContext context, RecurrenceRule? current) async {
  return showModalBottomSheet<RecurrenceRule>(
    context: context,
    backgroundColor: MFColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    isScrollControlled: true,
    builder: (ctx) => _RecurrencePicker(current: current),
  );
}

class _RecurrencePicker extends StatefulWidget {
  final RecurrenceRule? current;
  const _RecurrencePicker({this.current});

  @override
  State<_RecurrencePicker> createState() => _RecurrencePickerState();
}

class _RecurrencePickerState extends State<_RecurrencePicker> {
  late RecurrenceFrequency _freq;
  List<int> _weekdays = [];
  int? _monthDay;

  @override
  void initState() {
    super.initState();
    final r = widget.current;
    _freq = r?.frequency ?? RecurrenceFrequency.weekly;
    _weekdays = List.from(r?.weekdays ?? []);
    _monthDay = r?.monthDay;
  }

  RecurrenceRule get _rule =>
      RecurrenceRule(frequency: _freq, weekdays: _weekdays, monthDay: _monthDay);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(children: [
            const Expanded(
              child: Text(
                'Wiederholen',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: MFColors.textPrimary),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Entfernen',
                  style: TextStyle(color: const Color(0xFFEF4444))),
            ),
          ]),
          const SizedBox(height: 16),

          // Frequenz-Auswahl
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: RecurrenceFrequency.values.map((f) {
              final selected = _freq == f;
              return GestureDetector(
                onTap: () => setState(() {
                  _freq = f;
                  _weekdays = [];
                  _monthDay = null;
                }),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? MFColors.tealBg : MFColors.bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: selected ? MFColors.teal : MFColors.border),
                  ),
                  child: Text(
                    _freqLabel(f),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      color: selected ? MFColors.teal : MFColors.textSecondary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),

          // Wochentage (nur bei WEEKLY)
          if (_freq == RecurrenceFrequency.weekly) ...[
            const SizedBox(height: 16),
            const Text(
              'An welchen Tagen?',
              style: TextStyle(fontSize: 13, color: MFColors.textMuted),
            ),
            const SizedBox(height: 8),
            Row(
              children: List.generate(7, (i) {
                final selected = _weekdays.contains(i);
                final label =
                    const ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'][i];
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onTap: () => setState(() {
                      if (selected) {
                        _weekdays.remove(i);
                      } else {
                        _weekdays.add(i);
                        _weekdays.sort();
                      }
                    }),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: selected ? MFColors.teal : MFColors.bg,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: selected ? MFColors.teal : MFColors.border),
                      ),
                      child: Center(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: selected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: selected ? MFColors.bg : MFColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],

          // Tag des Monats (nur bei MONTHLY)
          if (_freq == RecurrenceFrequency.monthly) ...[
            const SizedBox(height: 16),
            Row(children: [
              const Text(
                'Am ',
                style: TextStyle(fontSize: 14, color: MFColors.textSecondary),
              ),
              DropdownButton<int?>(
                value: _monthDay,
                dropdownColor: MFColors.surface,
                style: const TextStyle(
                    fontSize: 14, color: MFColors.textPrimary),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('gleicher Tag',
                        style: TextStyle(color: MFColors.textMuted)),
                  ),
                  ...List.generate(
                      31,
                      (i) => DropdownMenuItem<int?>(
                            value: i + 1,
                            child: Text('${i + 1}.'),
                          )),
                ],
                onChanged: (v) => setState(() => _monthDay = v),
              ),
              if (_monthDay != null)
                const Text(
                  ' des Monats',
                  style:
                      TextStyle(fontSize: 14, color: MFColors.textSecondary),
                ),
            ]),
          ],

          const SizedBox(height: 20),

          // Vorschau
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: MFColors.bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: MFColors.border),
            ),
            child: Row(children: [
              const Icon(Icons.repeat_rounded, size: 14, color: MFColors.teal),
              const SizedBox(width: 8),
              Text(
                _rule.label,
                style: const TextStyle(fontSize: 13, color: MFColors.teal),
              ),
            ]),
          ),
          const SizedBox(height: 16),

          // Speichern-Button
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_rule),
              style: FilledButton.styleFrom(
                backgroundColor: MFColors.teal,
                foregroundColor: MFColors.bg,
              ),
              child: const Text('Übernehmen'),
            ),
          ),
        ],
      ),
    );
  }

  static String _freqLabel(RecurrenceFrequency f) => switch (f) {
        RecurrenceFrequency.daily => 'Täglich',
        RecurrenceFrequency.weekly => 'Wöchentlich',
        RecurrenceFrequency.monthly => 'Monatlich',
        RecurrenceFrequency.yearly => 'Jährlich',
      };
}
