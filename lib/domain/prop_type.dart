import 'package:flutter/material.dart';

enum PropType {
  text('text', 'Text', Icons.notes_rounded, Color(0xFF6B7280)),
  number('number', 'Zahl', Icons.pin_outlined, Color(0xFF3B82F6)),
  date('date', 'Datum', Icons.calendar_today_outlined, Color(0xFF8B5CF6)),
  boolean('boolean', 'Toggle', Icons.toggle_on_outlined, Color(0xFF10B981)),
  url('url', 'Link/URL', Icons.link_rounded, Color(0xFF60A5FA)),
  rating('rating', 'Bewertung', Icons.star_outline_rounded, Color(0xFFF59E0B)),
  tags('tags', 'Tags-Liste', Icons.label_outlined, Color(0xFF14B8A6)),
  select('select', 'Auswahl', Icons.list_outlined, Color(0xFFF97316));

  const PropType(this.value, this.label, this.icon, this.color);
  final String value;
  final String label;
  final IconData icon;
  final Color color;

  static PropType fromString(String s) =>
      PropType.values.firstWhere((t) => t.value == s,
          orElse: () => PropType.text);
}
