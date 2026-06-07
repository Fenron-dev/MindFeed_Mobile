# Konzepterweiterung: Erweiterte Filter + Multi-Select / Sammelbearbeitung

*Erarbeitet: 2026-06-07*

Zwei zusammenhängende Features. **Umsetzungsreihenfolge: erst Filter (Phase 1), danach Multi-Select (Phase 2).**

---

## Designentscheidungen (abgestimmt)

- **Filter-Logik:** DNF — **ODER von UND-Gruppen**. Innerhalb einer Gruppe UND, zwischen Gruppen ODER. Jede Bedingung kann negiert sein (`ist nicht`).
- **Chip-Leiste:** **Hybrid je Plattform** — Desktop: Inline-Tri-State-Chips; Mobile: Dropdowns.
- **Sortierung:** zusätzlich nach Property-Werten; erweiterter Screen (Mobile Fullscreen / Desktop Popup/rechter Frame).

---

# PHASE 1 — Erweiterte Filter

## Datenmodell (`lib/domain/feed_filter.dart`)

```dart
enum FilterField { status, type, tag, property, container, pinned, createdDate, dueDate }
enum FilterOp { is_, isNot, contains, notContains, exists, notExists, before, after, between }

class FilterCondition {
  FilterField field;
  FilterOp op;
  String? key;            // nur bei property
  String? value;          // Tag/Status/Typ/Text
  DateTime? date1, date2; // before/after/between
}
class FilterGroup { List<FilterCondition> conditions; }   // AND innerhalb
class FeedFilter {
  List<FilterGroup> groups;   // OR zwischen Gruppen
  String sortField;           // 'created'|'updated'|'due'|'title'|'prop:<key>'
  bool sortAsc;
}
class SavedFilter { String id; String name; String? emoji; FeedFilter filter; }
```

- Nur In-Memory (StateProvider) → keine DB-Migration.
- Status-Schnellbar wird in das Modell überführt (implizite erste Gruppe).

## Anwenden & Sortieren (`feed_screen.dart::_filterAndSort`)

- Treffer, wenn **mind. eine Gruppe** vollständig zutrifft (OR/AND).
- Felder: status/type/pinned (Entry-Felder), tag (`e.tags`), property (`e.properties`, Key + optional Wert), container (`e.containerIds`), createdDate/dueDate (`createdAt`/`reminderAt`, before/after/between).
- Sortierung erweitert: `prop:<key>` typgerecht (Zahl/Datum/Text).

## Gespeicherte Filter

- Persistenz analog `PropTemplate` (JSON-Liste in SharedPreferences): `loadSavedFilters()`/`saveSavedFilters()` in `app_settings.dart`.
- Provider `savedFiltersProvider` in `di.dart`.
- Aktionen: speichern (Name), anwenden, löschen; optional später „als Smart-Hub".

## Chip-Leiste (Hybrid)

**Tri-State** für Status/Typ-Schnellfilter: 1× = „nur dieser" (`is`), 2× = „alle außer diesem" (`isNot`), 3× = aus.
- **Desktop:** Inline-Chips (Alle, Inbox, Angeheftet, Erledigt, Archiviert, **Aufgaben**) + Button „Filter" + „Gespeichert ▾".
- **Mobile:** Dropdown „Typ/Status ▾" (Tri-State) + Dropdown „Gespeichert ▾" + Button „Filter".
- **Aktive Bedingungen** darunter als entfernbare Chips (X / erneuter Klick). Gespeicherter Filter als benannter Chip.

## Filter-Builder-Screen (`lib/features/feed/filter_builder_screen.dart`, neu)

- Visueller DNF-Builder: Gruppen (ODER) mit Bedingungen (UND), „+ Bedingung" / „+ ODER-Gruppe".
- Pro Bedingung: Feld → Operator → Wert (Autocomplete via `getUniqueKeys`/`getDistinctValues`/`getAllTagNames`; Datum via Picker).
- Sortier-Sektion (Feld + Richtung).
- Mobile: Fullscreen-Route; Desktop: breiter Dialog / rechter Frame. Große, mobiltaugliche Felder.

## Phase-1-Dateien
- `lib/domain/feed_filter.dart`, `lib/features/feed/feed_screen.dart`,
  `lib/features/feed/filter_builder_screen.dart` (neu),
  `lib/services/app_settings.dart`, `lib/core/di.dart`

---

# PHASE 2 — Multi-Select & Sammelbearbeitung

## Auswahl-State (`lib/features/selection/selection_provider.dart`, neu)
- `selectionModeProvider` (bool) + `selectedIdsProvider` (Set<String>) — app-weit (Feed + Aufgaben).
- Aktivierung: **Long-Press** → Auswahlmodus; Verlassen via X in der Toolbar.

## UI
- `entry_card.dart`: `selected` + `onSelectionToggle`, Checkbox-Overlay, im Auswahlmodus togglet Tap die Auswahl. (compact/mobile/desktop/`_GridCard`).
- `task_list_item.dart` + `_SubtaskRow`: analog.
- **Sammel-Toolbar** unten bei Auswahl (Feed + Aufgaben).

## Sammel-Aktionen
- **Löschen** (`deleteEntry`), **Status** (`updateEntry`/`toggleTaskStatus`), **Anheften** (`updateEntry(pinned:)`).
- **Container** zuweisen (Picker → `updateEntry(containerIds:)`).
- **Tags** hinzufügen/entfernen (`addTag`/`removeTag`).
- **Properties**: Sheet mit Key + Wert + **Modus Ersetzen / Anhängen / Entfernen** → neue Repo-Methode `setPropertyByKey(..., {append})`.
- **KI-Anreicherung für alle** (`OpenRouterService.enrichEntry` in Schleife, Fortschritts-Dialog, Fehler still überspringen).
- **Aufgaben erstellen/zuweisen**: je Eintrag `createTask(sourceEntryId:)` verlinkt; oder Auswahl an bestehende Aufgabe verlinken.

## Phase-2-Dateien
- `lib/features/selection/selection_provider.dart` (neu),
  `lib/features/selection/bulk_action_bar.dart` (+ Sheets, neu),
  `entry_card.dart`, `feed_screen.dart`, `task_overview_screen.dart`,
  `task_list_item.dart`, `entry_repository.dart` (`setPropertyByKey`).

---

## Verifikation
- Phase 1: kombinierte/negierte Bedingungen, Datumsbereiche, Property-Sortierung, gespeicherte Filter als Chip, Tri-State-Leiste.
- Phase 2: Long-Press-Auswahl in Feed+Aufgaben; alle Sammel-Aktionen; Properties Ersetzen/Anhängen/Entfernen; KI-Bulk mit Fortschritt.
- `flutter analyze` 0 Fehler; CI-Builds grün; manuell in der App testen.
