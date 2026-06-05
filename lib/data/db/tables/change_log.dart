import 'package:drift/drift.dart';

/// Änderungs-Journal für die Undo-Funktion.
/// Speichert vor jeder relevanten Änderung einen Snapshot des vorherigen
/// Zustands (beforeJson). Undo schreibt diesen Snapshot zurück.
class ChangeLog extends Table {
  TextColumn get id => text()();

  // 'entry' | 'container'
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();

  // 'edit' | 'status' | 'delete' | 'restore' | 'conflict_mine' | 'conflict_server'
  TextColumn get action => text()();

  // Menschlich lesbare Beschreibung (z.B. "Text geändert", "Als erledigt markiert")
  TextColumn get description => text()();

  // Vollständiger Snapshot des Eintrags VOR der Änderung (JSON).
  // null bei Aktionen ohne sinnvollen Vorzustand (z.B. Erstanlage).
  TextColumn get beforeJson => text().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  // true = bereits rückgängig gemacht (nicht erneut anwendbar)
  BoolColumn get undone => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}
