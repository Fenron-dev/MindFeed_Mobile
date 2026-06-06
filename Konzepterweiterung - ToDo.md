# Konzepterweiterung: ToDo-System

*Erarbeitet: 2026-06-06*

---

## Kernidee

Todos sind **vollwertige Entries vom Typ `task`** — keine separate Datenbanktabelle, sondern eine Erweiterung des bestehenden Entry-Systems. Damit funktionieren Suche, Sync, Verlauf, Tags, Container, Wikilinks und Attachments automatisch ohne extra Implementierungsaufwand.

---

## Features im Überblick

### Inline-Tasks in Notizen (Obsidian-kompatibel)

- Im Capture/Edit-Mode gibt es einen **Task-Button** in der Werkzeugleiste
- Klick fügt eine Task-Zeile ein: `- [ ] Aufgabe 📅 2025-01-15 🔁 weekly ⬆️`
- Enter → nächste Task-Zeile oder normaler Text weiterschreiben
- Beim Speichern: Parser erkennt alle `- [ ]`/`- [x]`-Zeilen → erstellt Task-Entry im Hintergrund → fügt Block-Referenz `^task-uuid` an die Zeile an
- In der Note-Ansicht (View-Mode, nicht Edit): Task-Zeilen werden als **live interaktive Checkboxen** gerendert — Status kommt direkt vom Task-Entry
- Checkbox-Klick in Note-View → togglet Task-Entry-Status (bidirektional)
- **Kein sofortiges Einstellungs-Popup** nach Enter — Details werden später über die Task-Detailseite gesetzt
- Toolbar-Sichtbarkeit per Einstellung umschaltbar (Mobile: immer sichtbar; Desktop: optional, Syntax-Eingabe ebenfalls möglich)

### Subtasks

- Inline-Tasks innerhalb einer Task-Note → Kind-Task via `parent_entry_id` (bereits vorhanden)
- In der Todo-Übersicht eingerückt unter dem Parent angezeigt, kollabierbar
- Herkunft ist immer sichtbar — kein "wo kommt das her?"-Problem

### Task-Detailseite (`/task/:id`)

Zeigt und ermöglicht Bearbeitung von:
- Titel + Status-Toggle (Checkbox oben)
- Fälligkeitsdatum (`reminderAt`-Feld)
- Priorität (Low / Medium / High / Urgent)
- Wiederholungsregel
- Tags + Container-Zuordnung
- Verlinkung: "Gehört zu Note: [Titel]" und "Gehört zu Projekt: [Name]"
- Subtasks (inline erstellbar)
- Änderungsjournal (via bestehendem ChangeLog)

### Todo-Übersicht (neuer Tab)

**Navigation:** Feed | **Tasks** | Suche | Einstellungen

Feste Gruppenstruktur:
1. **Überfällig** (rot, immer oben)
2. **Heute**
3. **Diese Woche**
4. **Später**
5. **Kein Datum**

Jede Task-Zeile zeigt: Priorität-Indikator · Checkbox · Titel · Fälligkeitsdatum · **Herkunft** (Notiz-Titel + Projekt, klein darunter)

Filter: Tags, Projekt/Container, Priorität, Status (offen / erledigt / archiviert), Herkunft

### Wiederkehrende Tasks

- Intern als **RRULE-String** (Standard, Kalender-kompatibel)
- UI: Täglich / Wöchentlich / Monatlich / Jährlich + Custom-Picker ("jeden X. des Monats", "jeden Di & Fr")
- Beim Abhaken: **sofort neue Instanz** mit nächstem Fälligkeitsdatum erstellen
- Alle Instanzen teilen eine `task_series_id`
- Beim Löschen: Dialog **"Nur diese Aufgabe"** oder **"Diese und alle folgenden"** (Outlook-Verhalten)

### Priorität

Eigenes Property `task_priority`: `low` / `medium` / `high` / `urgent`
Separat von `pinned` (pinned = temporär im Fokus behalten, unabhängig von Wichtigkeit)

### Notifications

`reminderAt`-Feld ist vorhanden → Flutter Local Notifications als Notification-Handler

---

## Datenmodell

### Schema-Migration v6

**`Entry.type`**: Neuer Wert `'task'` (neben `text | link | image | audio`)

**Neue EAV-Properties** (Schlüssel mit `task_`-Prefix, analog zu Template-Properties):

| Key | Typ | Beschreibung |
|-----|-----|-------------|
| `task_priority` | select | `low` / `medium` / `high` / `urgent` |
| `task_completed_at` | date | Zeitstempel der Erledigung |
| `task_recurrence` | text | RRULE-String (z.B. `FREQ=WEEKLY;BYDAY=TU,FR`) |
| `task_series_id` | text | UUID, geteilt von allen Instanzen einer Wiederholung |
| `task_source_entry_id` | text | UUID der Notiz, aus der dieser Task inline erstellt wurde |

**Bestehendes wird wiederverwendet:**
- `reminderAt` → Due Date
- `status` → `inbox`=offen, `active`=in Arbeit, `done`=erledigt, `archived`=abgebrochen
- `parent_entry_id` Property → Subtask-Verknüpfung
- Alle Linking-Mechanismen (Tags, Container, EntryLinks, Wikilinks)

---

## Neue & geänderte Dateien

### Neu
| Datei | Zweck |
|-------|-------|
| `lib/features/tasks/task_overview_screen.dart` | Haupt-Todo-View mit Gruppenköpfen |
| `lib/features/tasks/task_detail_screen.dart` | Task-Detailseite |
| `lib/features/tasks/task_provider.dart` | Riverpod StreamProvider für Tasks |
| `lib/features/tasks/widgets/task_list_item.dart` | Task-Zeile (Priorität, Checkbox, Herkunft) |
| `lib/features/tasks/widgets/task_filter_bar.dart` | Filter-Leiste |
| `lib/features/tasks/widgets/inline_task_toolbar.dart` | Toolbar-Button für Capture/Edit |
| `lib/domain/task_parser.dart` | Parser für `- [ ]`-Syntax + Block-Refs |
| `lib/domain/recurrence_calculator.dart` | RRULE-Berechnung (nächstes Datum) |

### Geändert
| Datei | Änderung |
|-------|---------|
| `lib/data/db/tables/entries.dart` | `'task'` zum type-Enum |
| `lib/data/db/app_database.dart` | Migration v6 |
| `lib/data/repositories/entry_repository.dart` | Task-spezifische Queries |
| `lib/features/capture/capture_screen.dart` | Task-Toolbar-Button + Task-Parsing beim Speichern |
| `lib/features/entry_detail/entry_detail_screen.dart` | Live-Checkboxen in View-Mode |
| `lib/core/router.dart` | Routen `/tasks`, `/task/:id` |
| `lib/widgets/app_shell.dart` | Tasks-Tab in Navigation |

---

## Implementierungsphasen

| Phase | Inhalt |
|-------|--------|
| 1 | Fundament: Schema v6, Task-Queries, Provider, leerer Tasks-Tab |
| 2 | Task-Detailseite, Todo-Übersicht mit Gruppen, Priorität, Due Date |
| 3 | Inline-Tasks: Parser, Toolbar, Capture-Integration, Live-Checkboxen in Note-View |
| 4 | Wiederkehrende Tasks (RRULE), Subtasks, Delete-Dialog |
| 5 | Filter-Leiste, Notifications, Shortcuts, Toolbar-Toggle-Setting |

---

## Keyboard Shortcuts (Desktop)

| Shortcut | Aktion |
|----------|--------|
| `Cmd+T` | Neuen Task erstellen |
| `Cmd+Shift+T` | Task zur aktuellen Notiz hinzufügen |
| `Space` | Task-Status toggling (fokussiert in Liste) |
| `Cmd+D` | Als erledigt markieren |
| `T` | Zum Tasks-Tab navigieren |

## Mobile Gesten

| Geste | Aktion |
|-------|--------|
| Wisch rechts auf Task | Als erledigt markieren |
| Wisch links auf Task | Archivieren/Löschen (mit Bestätigung) |
| Long Press | Kontextmenü |
| Tap Checkbox in Notiz | Status toggling |
| Tap Task-Titel in Notiz | Öffnet Task-Detailseite |

---

## Spätere Iterationen (nicht Teil dieser Implementierung)

- **Dashboard-Tab**: Heutige Tasks, aktuelle Notes, Statistiken, Media-Tracking (Serien, Bücher, Playlisten)
- **Kanban-View** für Tasks (erfordert Properties-Überarbeitung)
- **Natural Language Date Parsing** ("morgen", "nächsten Dienstag")
