import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import '../../../domain/recurrence_calculator.dart';

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
  int _interval = 1;
  List<int> _weekdays = [];
  int? _monthDay;
  int? _nthOccurrence;
  int? _nthWeekday;
  bool _useNth = false;
  TimeOfDay? _time;

  @override
  void initState() {
    super.initState();
    final r = widget.current;
    _freq = r?.frequency ?? RecurrenceFrequency.weekly;
    _interval = r?.interval ?? 1;
    _weekdays = List.from(r?.weekdays ?? []);
    _monthDay = r?.monthDay;
    _nthOccurrence = r?.nthOccurrence;
    _nthWeekday = r?.nthWeekday;
    _useNth = r?.nthOccurrence != null;
    if (r?.timeHour != null && r?.timeMinute != null) {
      _time = TimeOfDay(hour: r!.timeHour!, minute: r.timeMinute!);
    }
  }

  RecurrenceRule get _rule => RecurrenceRule(
        frequency: _freq,
        interval: _interval,
        weekdays: _weekdays,
        monthDay: _useNth ? null : _monthDay,
        nthOccurrence: _useNth ? (_nthOccurrence ?? 1) : null,
        nthWeekday: _useNth ? (_nthWeekday ?? 0) : null,
        timeHour: _time?.hour,
        timeMinute: _time?.minute,
      );

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? TimeOfDay.now(),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: MFColors.teal,
            surface: MFColors.surface,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _time = picked);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header
          Row(children: [
            const Expanded(
              child: Text('Wiederholen',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold,
                      color: MFColors.textPrimary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Entfernen',
                  style: TextStyle(color: Color(0xFFEF4444))),
            ),
          ]),
          const SizedBox(height: 16),

          // ── Frequenz
          const Text('Häufigkeit',
              style: TextStyle(fontSize: 12, color: MFColors.textMuted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8, runSpacing: 8,
            children: RecurrenceFrequency.values.map((f) {
              final sel = _freq == f;
              return GestureDetector(
                onTap: () => setState(() {
                  _freq = f;
                  _weekdays = [];
                  _monthDay = null;
                  _nthOccurrence = null;
                  _nthWeekday = null;
                  _useNth = false;
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: sel ? MFColors.tealBg : MFColors.bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: sel ? MFColors.teal : MFColors.border),
                  ),
                  child: Text(_freqLabel(f),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
                          color: sel ? MFColors.teal : MFColors.textSecondary)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // ── Intervall
          Row(children: [
            const Text('Alle ',
                style: TextStyle(fontSize: 14, color: MFColors.textSecondary)),
            SizedBox(
              width: 60,
              child: TextFormField(
                initialValue: '$_interval',
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 14, color: MFColors.textPrimary),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  border: OutlineInputBorder(),
                  focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: MFColors.teal)),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 1) setState(() => _interval = n);
                },
              ),
            ),
            const SizedBox(width: 8),
            Text(_freqUnitLabel(_freq, _interval),
                style: const TextStyle(fontSize: 14, color: MFColors.textSecondary)),
          ]),

          // ── Wochentage (nur bei WEEKLY)
          if (_freq == RecurrenceFrequency.weekly) ...[
            const SizedBox(height: 16),
            const Text('An welchen Tagen?',
                style: TextStyle(fontSize: 12, color: MFColors.textMuted)),
            const SizedBox(height: 8),
            Row(children: List.generate(7, (i) {
              final sel = _weekdays.contains(i);
              final label = const ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'][i];
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => setState(() {
                    if (sel) _weekdays.remove(i);
                    else { _weekdays.add(i); _weekdays.sort(); }
                  }),
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: sel ? MFColors.teal : MFColors.bg,
                      shape: BoxShape.circle,
                      border: Border.all(color: sel ? MFColors.teal : MFColors.border),
                    ),
                    child: Center(
                      child: Text(label,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                              color: sel ? MFColors.bg : MFColors.textSecondary)),
                    ),
                  ),
                ),
              );
            })),
          ],

          // ── Monatlich: Tag oder Nth-Wochentag
          if (_freq == RecurrenceFrequency.monthly) ...[
            const SizedBox(height: 16),
            Row(children: [
              _ModeChip('Am Tag', !_useNth, () => setState(() => _useNth = false)),
              const SizedBox(width: 8),
              _ModeChip('Am Wochentag', _useNth, () => setState(() => _useNth = true)),
            ]),
            const SizedBox(height: 12),
            if (!_useNth)
              Row(children: [
                const Text('Am ',
                    style: TextStyle(fontSize: 14, color: MFColors.textSecondary)),
                DropdownButton<int?>(
                  value: _monthDay,
                  dropdownColor: MFColors.surface,
                  style: const TextStyle(fontSize: 14, color: MFColors.textPrimary),
                  items: [
                    const DropdownMenuItem<int?>(value: null,
                        child: Text('wie Fälligkeitsdat.',
                            style: TextStyle(color: MFColors.textMuted, fontSize: 12))),
                    ...List.generate(31, (i) =>
                        DropdownMenuItem<int?>(value: i + 1, child: Text('${i + 1}.'))),
                  ],
                  onChanged: (v) => setState(() => _monthDay = v),
                ),
                if (_monthDay != null)
                  const Text(' des Monats',
                      style: TextStyle(fontSize: 14, color: MFColors.textSecondary)),
              ])
            else
              Row(children: [
                DropdownButton<int>(
                  value: _nthOccurrence ?? 1,
                  dropdownColor: MFColors.surface,
                  style: const TextStyle(fontSize: 14, color: MFColors.textPrimary),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1.')),
                    DropdownMenuItem(value: 2, child: Text('2.')),
                    DropdownMenuItem(value: 3, child: Text('3.')),
                    DropdownMenuItem(value: 4, child: Text('4.')),
                    DropdownMenuItem(value: -1, child: Text('Letzten')),
                  ],
                  onChanged: (v) => setState(() => _nthOccurrence = v ?? 1),
                ),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _nthWeekday ?? 0,
                  dropdownColor: MFColors.surface,
                  style: const TextStyle(fontSize: 14, color: MFColors.textPrimary),
                  items: List.generate(7, (i) {
                    final n =
                        const ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag',
                            'Freitag', 'Samstag', 'Sonntag'][i];
                    return DropdownMenuItem(value: i, child: Text(n));
                  }),
                  onChanged: (v) => setState(() => _nthWeekday = v ?? 0),
                ),
              ]),
          ],

          // ── Uhrzeit
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _pickTime,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: MFColors.bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: MFColors.border),
              ),
              child: Row(children: [
                Icon(Icons.access_time_rounded, size: 16,
                    color: _time != null ? MFColors.teal : MFColors.textMuted),
                const SizedBox(width: 8),
                Text(
                  _time != null
                      ? '${_time!.hour.toString().padLeft(2, '0')}:${_time!.minute.toString().padLeft(2, '0')} Uhr'
                      : 'Keine Uhrzeit',
                  style: TextStyle(
                      fontSize: 14,
                      color: _time != null ? MFColors.teal : MFColors.textMuted),
                ),
                if (_time != null) ...[
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _time = null),
                    child: const Icon(Icons.close_rounded,
                        size: 14, color: MFColors.textMuted),
                  ),
                ],
              ]),
            ),
          ),

          // ── Vorschau
          const SizedBox(height: 16),
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
              Expanded(
                child: Text(_rule.label,
                    style: const TextStyle(fontSize: 13, color: MFColors.teal)),
              ),
            ]),
          ),
          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_rule),
              style: FilledButton.styleFrom(
                  backgroundColor: MFColors.teal, foregroundColor: MFColors.bg),
              child: const Text('Übernehmen'),
            ),
          ),
        ],
      ),
    );
  }

  static String _freqLabel(RecurrenceFrequency f) => switch (f) {
        RecurrenceFrequency.minutely => 'Minütlich',
        RecurrenceFrequency.hourly   => 'Stündlich',
        RecurrenceFrequency.daily    => 'Täglich',
        RecurrenceFrequency.weekly   => 'Wöchentlich',
        RecurrenceFrequency.monthly  => 'Monatlich',
        RecurrenceFrequency.yearly   => 'Jährlich',
      };

  static String _freqUnitLabel(RecurrenceFrequency f, int n) => switch (f) {
        RecurrenceFrequency.minutely => n == 1 ? 'Minute' : 'Minuten',
        RecurrenceFrequency.hourly   => n == 1 ? 'Stunde' : 'Stunden',
        RecurrenceFrequency.daily    => n == 1 ? 'Tag' : 'Tage',
        RecurrenceFrequency.weekly   => n == 1 ? 'Woche' : 'Wochen',
        RecurrenceFrequency.monthly  => n == 1 ? 'Monat' : 'Monate',
        RecurrenceFrequency.yearly   => n == 1 ? 'Jahr' : 'Jahre',
      };
}

class _ModeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ModeChip(this.label, this.selected, this.onTap);

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? MFColors.tealBg : MFColors.bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? MFColors.teal : MFColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? MFColors.teal : MFColors.textSecondary)),
        ),
      );
}
