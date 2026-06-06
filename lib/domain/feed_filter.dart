/// Aktiver Feed-Filter — wird via feedFilterProvider gehalten.
class FeedFilter {
  /// null = alle Typen; 'text' | 'link' | 'image' | 'audio'
  final String? entryType;

  /// Property-Regeln: key → gewünschter Wert (null = nur Existenz prüfen)
  final Map<String, String?> propRules;

  /// Tags, die der Eintrag haben muss (UND-Verknüpfung).
  final List<String> tags;

  const FeedFilter({this.entryType, this.propRules = const {}, this.tags = const []});

  bool get isActive => entryType != null || propRules.isNotEmpty || tags.isNotEmpty;

  FeedFilter copyWith({String? entryType, Map<String, String?>? propRules,
      List<String>? tags, bool clearType = false}) =>
      FeedFilter(
        entryType: clearType ? null : (entryType ?? this.entryType),
        propRules: propRules ?? this.propRules,
        tags: tags ?? this.tags,
      );
}
