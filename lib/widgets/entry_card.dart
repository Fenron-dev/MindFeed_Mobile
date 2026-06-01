import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/theme.dart';
import '../data/repositories/entry_repository.dart';

class EntryCard extends StatelessWidget {
  final EntryWithDetails item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool compact;

  const EntryCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final entry = item.entry;
    final isPinned = entry.pinned;
    final isInbox = entry.status == 'inbox';
    final isDone = entry.status == 'done';

    if (compact) {
      return InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: MFColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isPinned ? const Color(0xFF831843) : MFColors.border,
            ),
          ),
          child: Row(children: [
            _TypeIcon(entry.type),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                entry.title ?? _stripMarkdown(entry.body),
                style: TextStyle(
                  fontSize: 13,
                  color: isDone ? MFColors.textMuted : MFColors.textPrimary,
                  decoration: isDone ? TextDecoration.lineThrough : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              DateFormat('dd.MM.yy').format(entry.createdAt.toLocal()),
              style: const TextStyle(
                  fontSize: 10, color: MFColors.textMuted, fontFamily: 'monospace'),
            ),
            if (isPinned) ...[
              const SizedBox(width: 4),
              const Icon(Icons.push_pin_rounded, size: 12, color: MFColors.pinned),
            ],
            if (isInbox) ...[
              const SizedBox(width: 4),
              const Icon(Icons.inbox_outlined, size: 12, color: MFColors.inbox),
            ],
          ]),
        ),
      );
    }

    // Cover-Bild: erst Properties (og_image), dann Bild-Anhänge
    final coverUrl = item.properties
        .where((p) =>
            ['og_image', 'cover_image', 'cover', 'bild'].contains(p.key.toLowerCase()))
        .firstOrNull
        ?.value;
    final coverLocalPath = coverUrl == null
        ? item.attachments
            .where((a) => a.type == 'image')
            .firstOrNull
            ?.localPath
        : null;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: MFColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isPinned ? const Color(0xFF831843) : MFColors.border,
            width: isPinned ? 1.5 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ─── Cover-Bild (optional) ───────────────────────────
              if (coverUrl != null || coverLocalPath != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: coverUrl != null
                      ? Image.network(
                          coverUrl,
                          width: 56,
                          height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        )
                      : Image.file(
                          File(coverLocalPath!),
                          width: 56,
                          height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                ),
                const SizedBox(width: 10),
              ],

              // ─── Inhalt ───────────────────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Metazeile: Icon + Datum + Pin
                    Row(
                      children: [
                        _TypeIcon(entry.type),
                        const SizedBox(width: 5),
                        Text(
                          DateFormat('dd.MM.yy HH:mm').format(entry.createdAt.toLocal()),
                          style: const TextStyle(
                            fontSize: 10,
                            color: MFColors.textMuted,
                            fontFamily: 'monospace',
                          ),
                        ),
                        if (entry.sourceApp != null) ...[
                          const Text(' · ',
                              style: TextStyle(
                                  fontSize: 10, color: MFColors.textMuted)),
                          Text(
                            entry.sourceApp!,
                            style: const TextStyle(
                                fontSize: 10, color: MFColors.textMuted),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const Spacer(),
                        if (isPinned)
                          const Icon(Icons.push_pin_rounded,
                              size: 13, color: MFColors.pinned),
                        if (isInbox)
                          const Icon(Icons.inbox_outlined,
                              size: 13, color: MFColors.inbox),
                        if (isDone)
                          const Icon(Icons.check_circle_outline,
                              size: 13, color: MFColors.done),
                      ],
                    ),

                    const SizedBox(height: 5),

                    // Titel
                    if (entry.title != null && entry.title!.isNotEmpty)
                      Text(
                        entry.title!,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDone
                              ? MFColors.textMuted
                              : MFColors.textPrimary,
                          decoration: isDone
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),

                    const SizedBox(height: 3),

                    // Body-Preview
                    if (entry.body.isNotEmpty)
                      Text(
                        _stripMarkdown(entry.body),
                        style: const TextStyle(
                          fontSize: 12,
                          color: MFColors.textSecondary,
                          height: 1.45,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),

                    // Tags
                    if (item.tags.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 5,
                        runSpacing: 3,
                        children: item.tags
                            .take(5)
                            .map((tag) => _TagChip(tag))
                            .toList(),
                      ),
                    ],

                    // Properties-Vorschau (max. 3, konfigurierbar — TODO Templates)
                    if (item.properties.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _PropertiesRow(item.properties),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _stripMarkdown(String text) =>
      text.replaceAll(RegExp(r'[#*`_\[\]\(\)>|\-]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
}

// ─── Kleine Subwidgets ────────────────────────────────────────────────────────

class _TypeIcon extends StatelessWidget {
  final String type;
  const _TypeIcon(this.type);

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (type) {
      'link' => (Icons.link_rounded, const Color(0xFF60A5FA)),
      'image' => (Icons.image_outlined, const Color(0xFFA78BFA)),
      'audio' => (Icons.mic_outlined, const Color(0xFFC084FC)),
      _ => (Icons.notes_rounded, MFColors.textMuted),
    };
    return Icon(icon, size: 12, color: color);
  }
}

class _TagChip extends StatelessWidget {
  final String tag;
  const _TagChip(this.tag);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: MFColors.tealBg,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: const Color(0xFF0F766E), width: 0.5),
      ),
      child: Text(
        '#$tag',
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: MFColors.teal,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

class _PropertiesRow extends StatelessWidget {
  final List properties;
  const _PropertiesRow(this.properties);

  static const _excludedKeys = {
    'og_image', 'cover_image', 'cover', 'bild',
    'og_description', 'og_title',
  };

  @override
  Widget build(BuildContext context) {
    final visible = properties
        .where((p) => !_excludedKeys.contains(p.key.toLowerCase()))
        .take(3)
        .toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 3,
      children: visible.map((p) {
        final valStr = p.value ?? '';
        final display = valStr.length > 20 ? '${valStr.substring(0, 20)}…' : valStr;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: MFColors.bg,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: MFColors.border),
          ),
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                    text: '${p.key}: ',
                    style: const TextStyle(
                        fontSize: 10,
                        color: MFColors.textMuted,
                        fontFamily: 'monospace')),
                TextSpan(
                    text: display,
                    style: const TextStyle(
                        fontSize: 10,
                        color: MFColors.textPrimary,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
