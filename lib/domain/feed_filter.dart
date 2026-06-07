import 'dart:convert';

/// Feld, auf das sich eine Filterbedingung bezieht.
enum FilterField { status, type, tag, property, container, pinned, createdDate, dueDate }

/// Operator einer Filterbedingung.
enum FilterOp { is_, isNot, contains, notContains, exists, notExists, before, after, between }

/// Eine einzelne Filterbedingung.
class FilterCondition {
  final FilterField field;
  final FilterOp op;
  final String? key;       // nur bei property: der Property-Schlüssel
  final String? value;     // Tag-Name / Status / Typ / Container-ID / Textwert
  final DateTime? date1;   // before/after/between
  final DateTime? date2;   // between (Ende)

  const FilterCondition({
    required this.field,
    required this.op,
    this.key,
    this.value,
    this.date1,
    this.date2,
  });

  FilterCondition copyWith({
    FilterField? field, FilterOp? op, String? key, String? value,
    DateTime? date1, DateTime? date2,
  }) =>
      FilterCondition(
        field: field ?? this.field,
        op: op ?? this.op,
        key: key ?? this.key,
        value: value ?? this.value,
        date1: date1 ?? this.date1,
        date2: date2 ?? this.date2,
      );

  Map<String, dynamic> toJson() => {
        'field': field.name,
        'op': op.name,
        if (key != null) 'key': key,
        if (value != null) 'value': value,
        if (date1 != null) 'date1': date1!.toIso8601String(),
        if (date2 != null) 'date2': date2!.toIso8601String(),
      };

  static FilterCondition fromJson(Map<String, dynamic> j) => FilterCondition(
        field: FilterField.values.firstWhere((f) => f.name == j['field'],
            orElse: () => FilterField.tag),
        op: FilterOp.values.firstWhere((o) => o.name == j['op'],
            orElse: () => FilterOp.is_),
        key: j['key'] as String?,
        value: j['value'] as String?,
        date1: j['date1'] != null ? DateTime.tryParse(j['date1'] as String) : null,
        date2: j['date2'] != null ? DateTime.tryParse(j['date2'] as String) : null,
      );
}

/// Eine Gruppe von Bedingungen — innerhalb UND-verknüpft.
class FilterGroup {
  final List<FilterCondition> conditions;
  const FilterGroup({this.conditions = const []});

  FilterGroup copyWith({List<FilterCondition>? conditions}) =>
      FilterGroup(conditions: conditions ?? this.conditions);

  Map<String, dynamic> toJson() =>
      {'conditions': conditions.map((c) => c.toJson()).toList()};

  static FilterGroup fromJson(Map<String, dynamic> j) => FilterGroup(
        conditions: ((j['conditions'] as List?) ?? [])
            .map((c) => FilterCondition.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}

/// Aktiver Feed-Filter (DNF): Gruppen sind ODER-verknüpft, Bedingungen
/// innerhalb einer Gruppe UND-verknüpft. Plus Sortierung.
class FeedFilter {
  final List<FilterGroup> groups;
  final String sortField; // 'created' | 'updated' | 'due' | 'title' | 'prop:<key>'
  final bool sortAsc;

  const FeedFilter({
    this.groups = const [],
    this.sortField = 'created',
    this.sortAsc = false,
  });

  bool get hasConditions =>
      groups.any((g) => g.conditions.isNotEmpty);

  bool get isActive => hasConditions;

  /// Alle Bedingungen flach (für aktive-Chips-Anzeige & Entfernen).
  Iterable<FilterCondition> get allConditions =>
      groups.expand((g) => g.conditions);

  FeedFilter copyWith({
    List<FilterGroup>? groups,
    String? sortField,
    bool? sortAsc,
  }) =>
      FeedFilter(
        groups: groups ?? this.groups,
        sortField: sortField ?? this.sortField,
        sortAsc: sortAsc ?? this.sortAsc,
      );

  /// Fügt eine Bedingung der ersten Gruppe hinzu (für Schnellfilter/Chips).
  FeedFilter withCondition(FilterCondition c) {
    final gs = groups.isEmpty
        ? [const FilterGroup()]
        : List<FilterGroup>.from(groups);
    final first = gs[0];
    gs[0] = first.copyWith(conditions: [...first.conditions, c]);
    return copyWith(groups: gs);
  }

  /// Entfernt alle Bedingungen, die das Prädikat erfüllen; leere Gruppen raus.
  FeedFilter removeWhere(bool Function(FilterCondition) test) {
    final gs = groups
        .map((g) => g.copyWith(
            conditions: g.conditions.where((c) => !test(c)).toList()))
        .where((g) => g.conditions.isNotEmpty)
        .toList();
    return copyWith(groups: gs);
  }

  Map<String, dynamic> toJson() => {
        'groups': groups.map((g) => g.toJson()).toList(),
        'sortField': sortField,
        'sortAsc': sortAsc,
      };

  static FeedFilter fromJson(Map<String, dynamic> j) => FeedFilter(
        groups: ((j['groups'] as List?) ?? [])
            .map((g) => FilterGroup.fromJson(g as Map<String, dynamic>))
            .toList(),
        sortField: j['sortField'] as String? ?? 'created',
        sortAsc: j['sortAsc'] as bool? ?? false,
      );
}

/// Menschenlesbares Label einer Bedingung (für aktive Chips + Builder).
String conditionLabel(FilterCondition c) {
  final neg = (c.op == FilterOp.isNot ||
          c.op == FilterOp.notContains ||
          c.op == FilterOp.notExists)
      ? '≠ '
      : '';
  String fmt(DateTime? d) => d == null ? '?' : '${d.day}.${d.month}.${d.year}';
  switch (c.field) {
    case FilterField.status:
      return '${neg}Status: ${c.value}';
    case FilterField.type:
      return '${neg}Typ: ${c.value}';
    case FilterField.pinned:
      return neg.isEmpty ? 'Angeheftet' : 'Nicht angeheftet';
    case FilterField.tag:
      return '$neg#${c.value}';
    case FilterField.container:
      return '${neg}Container';
    case FilterField.property:
      final base = c.key ?? 'Eigenschaft';
      if (c.op == FilterOp.exists) return '$base ✓';
      if (c.op == FilterOp.notExists) return '$base ✗';
      return '$neg$base: ${c.value ?? ''}';
    case FilterField.createdDate:
    case FilterField.dueDate:
      final lbl = c.field == FilterField.dueDate ? 'Fällig' : 'Erstellt';
      if (c.op == FilterOp.before) return '$lbl < ${fmt(c.date1)}';
      if (c.op == FilterOp.after) return '$lbl > ${fmt(c.date1)}';
      return '$lbl ${fmt(c.date1)}–${fmt(c.date2)}';
  }
}

/// Ein benannter, gespeicherter Filter.
class SavedFilter {
  final String id;
  final String name;
  final String? emoji;
  final FeedFilter filter;

  const SavedFilter({
    required this.id,
    required this.name,
    this.emoji,
    required this.filter,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (emoji != null) 'emoji': emoji,
        'filter': filter.toJson(),
      };

  static SavedFilter fromJson(Map<String, dynamic> j) => SavedFilter(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Filter',
        emoji: j['emoji'] as String?,
        filter: FeedFilter.fromJson(
            (j['filter'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );

  String encode() => jsonEncode(toJson());
  static SavedFilter decode(String s) =>
      SavedFilter.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
