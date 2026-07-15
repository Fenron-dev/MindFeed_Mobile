import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../domain/entry_kind.dart';

/// Kompakter, tappbarer Chip für den semantischen [EntryKind] eines Eintrags.
/// Zeigt Icon + Label in der Kind-Farbe; ohne Kind einen neutralen
/// „Typ wählen"-Hinweis. Tippen öffnet [showKindPicker].
class KindChip extends StatelessWidget {
  final EntryKind? kind;
  final VoidCallback? onTap;

  const KindChip({super.key, required this.kind, this.onTap});

  @override
  Widget build(BuildContext context) {
    final k = kind;
    final color = k?.color ?? MFColors.textMuted;
    final icon = k?.icon ?? Icons.help_outline_rounded;
    final label = k?.label ?? 'Typ wählen';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace')),
          if (onTap != null) ...[
            const SizedBox(width: 3),
            Icon(Icons.expand_more_rounded, size: 13, color: color),
          ],
        ]),
      ),
    );
  }
}

/// Bottom-Sheet zur Auswahl eines [EntryKind]. Liefert den gewählten Kind
/// oder `null` (Abbruch). [current] wird hervorgehoben.
Future<EntryKind?> showKindPicker(BuildContext context,
    {EntryKind? current}) {
  return showModalBottomSheet<EntryKind>(
    context: context,
    backgroundColor: MFColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: MFColors.border,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const Text('Typ wählen',
                  style: TextStyle(
                      color: MFColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: EntryKind.values.map((k) {
                  final selected = k == current;
                  return InkWell(
                    onTap: () => Navigator.pop(ctx, k),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(
                        color: selected
                            ? k.color.withValues(alpha: 0.18)
                            : MFColors.bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected
                              ? k.color
                              : MFColors.border,
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(k.icon, size: 16, color: k.color),
                        const SizedBox(width: 7),
                        Text(k.label,
                            style: TextStyle(
                                color: selected
                                    ? MFColors.textPrimary
                                    : MFColors.textSecondary,
                                fontSize: 13,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.normal)),
                      ]),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      );
    },
  );
}
