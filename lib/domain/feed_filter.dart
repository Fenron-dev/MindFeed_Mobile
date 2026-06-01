/// Aktiver Feed-Filter — wird via feedFilterProvider gehalten.
class FeedFilter {
  /// null = alle Typen; 'text' | 'link' | 'image' | 'audio'
  final String? entryType;

  /// Property-Regeln: key → gewünschter Wert (null = nur Existenz prüfen)
  final Map<String, String?> propRules;

  const FeedFilter({this.entryType, this.propRules = const {}});

  bool get isActive => entryType != null || propRules.isNotEmpty;

  FeedFilter copyWith({String? entryType, Map<String, String?>? propRules,
      bool clearType = false}) =>
      FeedFilter(
        entryType: clearType ? null : (entryType ?? this.entryType),
        propRules: propRules ?? this.propRules,
      );
}
