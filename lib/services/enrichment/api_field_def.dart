import '../../domain/prop_type.dart';

/// Beschreibt ein einzelnes Feld, das eine API liefern kann.
///
/// Aus diesen Definitionen wird die Einstellungen-UI, die Abhol-Vorschau und
/// der Import generiert. Ein Feld ist „bekannt", sobald es im
/// [ApiFieldCatalog] steht — unabhängig davon, ob die API es im Einzelfall
/// tatsächlich füllt.
class ApiFieldDef {
  /// Stabiler Schlüssel innerhalb der Quelle (z.B. `studio`, `episodes`).
  /// Wird in [ApiFieldPrefs] persistiert und als Map-Key im MetadataRecord
  /// verwendet.
  final String key;

  /// Anzeige-Label in UI und (als Property-Key) im Eintrag.
  final String label;

  /// Werttyp — steuert Rendering in der Vorschau und den Property-Typ.
  final PropType type;

  /// Optionale Gruppierung in der Einstellungen-/Vorschau-UI (z.B. „Basis").
  final String? group;

  /// Kanonischer Property-Key, unter dem das Feld bisher gespeichert wird
  /// (z.B. `anilist_studio`, `github_stars`, `og_image`). Erhält die
  /// Kompatibilität bestehender Feed-Karten/Detail-Ansichten. Fehlt er, wird
  /// [label] als Property-Key verwendet (generisches neues Feld).
  final String? propKey;

  /// Ob das Feld standardmäßig importiert wird (Default-Auswahl in den
  /// Einstellungen, bevor der Nutzer etwas ändert).
  final bool defaultEnabled;

  const ApiFieldDef({
    required this.key,
    required this.label,
    this.type = PropType.text,
    this.group,
    this.propKey,
    this.defaultEnabled = true,
  });

  /// Property-Key, unter dem dieses Feld in den Eintrag geschrieben wird.
  String get storageKey => propKey ?? label;

  /// Legacy-String des Property-Typs, wie ihn das EntryProperties-Schema
  /// erwartet (`string` / `number` / `url`). Bool/Date/Rating/Tags/Select
  /// werden als `string` abgelegt — konsistent mit dem bisherigen Verhalten.
  String get legacyPropType {
    switch (type) {
      case PropType.number:
        return 'number';
      case PropType.url:
        return 'url';
      default:
        return 'string';
    }
  }
}
