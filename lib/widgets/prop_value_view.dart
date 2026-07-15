import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../domain/prop_type.dart';

/// Reine Format-Interpretation für Property-Werte (DB-Werte bleiben Strings).
class PropValueFormat {
  const PropValueFormat._();

  /// ISO-Datum → `dd.mm.yyyy`, sonst `null`.
  static String? asDate(String v) {
    final dt = DateTime.tryParse(v);
    if (dt == null) return null;
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    return '$d.$m.${dt.year}';
  }

  /// Host einer URL ohne `www.` (Fallback: Originalwert).
  static String urlHost(String v) =>
      Uri.tryParse(v)?.host.replaceFirst('www.', '') ?? v;

  /// Komma-separierte Liste → getrimmte, nicht-leere Elemente.
  static List<String> asList(String v) =>
      v.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

  /// Rating als 0–5 geclampt.
  static int rating(String v) => (int.tryParse(v) ?? 0).clamp(0, 5);

  static bool asBool(String v) => v == 'true';

  /// Inferiert einen [PropType] aus einem rohen String — nur zur Darstellung,
  /// wenn kein expliziter Typ vorliegt.
  static PropType infer(String v) {
    if (v == 'true' || v == 'false') return PropType.boolean;
    if (num.tryParse(v) != null) return PropType.number;
    if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(v) &&
        DateTime.tryParse(v) != null) {
      return PropType.date;
    }
    return PropType.text;
  }
}

/// Kompakte, nicht-interaktive Darstellung eines Property-Werts für Chips.
/// Gemeinsam genutzt von der mobilen und der Desktop-Feed-Karte — ersetzt die
/// zuvor doppelte `_renderValue`-Logik in `entry_card.dart`.
class CompactPropValue extends StatelessWidget {
  final PropType type;
  final String value;
  final double fontSize;
  final double boolIconSize;
  final double starSize;

  /// Mobil: Text einzeilig mit Ellipsis. Desktop: voller Text.
  final bool ellipsis;

  /// Desktop: Tags als eigene Mini-Chips statt komma-verkürzter Text.
  final bool tagsAsChips;

  const CompactPropValue._({
    required this.type,
    required this.value,
    required this.fontSize,
    required this.boolIconSize,
    required this.starSize,
    required this.ellipsis,
    required this.tagsAsChips,
  });

  const CompactPropValue.mobile({required PropType type, required String value})
      : this._(
          type: type,
          value: value,
          fontSize: 10,
          boolIconSize: 11,
          starSize: 10,
          ellipsis: true,
          tagsAsChips: false,
        );

  const CompactPropValue.desktop(
      {required PropType type, required String value})
      : this._(
          type: type,
          value: value,
          fontSize: 11,
          boolIconSize: 13,
          starSize: 12,
          ellipsis: false,
          tagsAsChips: true,
        );

  TextStyle get _vs =>
      TextStyle(fontSize: fontSize, fontFamily: 'monospace');

  Text _text(String s, {Color? color}) => Text(
        s,
        style: _vs.copyWith(color: color ?? MFColors.textPrimary),
        overflow: ellipsis ? TextOverflow.ellipsis : null,
        maxLines: ellipsis ? 1 : null,
      );

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return _text('—', color: MFColors.textMuted);

    switch (type) {
      case PropType.boolean:
        final isOn = PropValueFormat.asBool(value);
        return Icon(
          isOn ? Icons.check_circle_outline : Icons.radio_button_unchecked,
          size: boolIconSize,
          color: isOn ? const Color(0xFF10B981) : MFColors.textMuted,
        );
      case PropType.rating:
        final stars = PropValueFormat.rating(value);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            stars,
            (_) => Icon(Icons.star_rounded,
                size: starSize, color: const Color(0xFFF59E0B)),
          ),
        );
      case PropType.date:
        return _text(PropValueFormat.asDate(value) ?? value);
      case PropType.url:
        return _text(PropValueFormat.urlHost(value),
            color: const Color(0xFF60A5FA));
      case PropType.tags:
        final tags = PropValueFormat.asList(value);
        if (tagsAsChips) {
          return Wrap(
            spacing: 4,
            children: tags
                .map((t) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: MFColors.teal.withAlpha(25),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: MFColors.teal.withAlpha(80)),
                      ),
                      child: Text(t,
                          style: const TextStyle(
                              fontSize: 10,
                              color: MFColors.teal,
                              fontFamily: 'monospace')),
                    ))
                .toList(),
          );
        }
        return _text(tags.take(2).join(', '), color: MFColors.teal);
      default:
        return _text(value);
    }
  }
}
