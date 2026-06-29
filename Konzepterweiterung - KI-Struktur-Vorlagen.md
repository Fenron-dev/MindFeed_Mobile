# Konzepterweiterung: Editierbare KI-Struktur-Vorlagen

*Erarbeitet: 2026-06-27 · Issue #38*

---

## Kernidee

Heute steckt die **Struktur** der KI-Notizen fest im Code: `generateStructuredNote`
erkennt einen Typ (TUTORIAL/NEWS/REVIEW/INTERVIEW/ENTERTAINMENT/**REZEPT**/GENERISCH)
und schreibt die Notiz nach einem **fest verdrahteten Markdown-Gerüst** je Typ.
Ebenso ist die **recherchierte Notiz** (`generateResearchedNote`) mit fester Struktur
verdrahtet. Der Nutzer sieht und ändert davon nichts.

Künftig sind diese **Gerüste in den Einstellungen sichtbar und anpassbar**: man sieht
z.B. wie ein als „Rezept" erkanntes YouTube-Video formatiert wird, kann das Gerüst
ändern, Typen ergänzen/löschen und die Recherche-Struktur editieren. Die
**Auto-Typ-Erkennung bleibt Default**; beim Anreichern kann der Typ **optional erzwungen**
werden (z.B. „als Rezept strukturieren").

Design-Vorbild im Projekt: die bereits vorhandenen **Property-Templates**
(`PropTemplate` + `_TemplatesSection`/`_TemplateEditor`) — gleiches Muster aus
JSON-Liste in SharedPreferences und Add/Edit/Delete-Editor.

---

## Features im Überblick

### Struktur-Vorlagen (strukturierte Notiz)
- Pro Typ eine **Vorlage**: `name` (z.B. „Rezept") + `skeleton` (das Markdown-`##`-Gerüst
  inkl. Hinweisen, z.B. Tabellen-Hinweise).
- **Hinzufügen / Bearbeiten / Löschen** eigener Typen; „**Auf Standard zurücksetzen**".
- Auslieferungs-Default = die **7 heutigen Gerüste 1:1** → ohne Änderung exakt gleiches
  Verhalten wie bisher.

### Recherche-Struktur (recherchierte Notiz)
- Die „STRUKTUR"-Sektion (`## Beschreibung / ## Systemvoraussetzungen / ## Installation /
  ## Mögliche Risiken / ## Mögliche Alternativen`) wird **ein editierbares Textfeld** + Reset.

### Typ: Auto + manuell überschreibbar
- Default: KI erkennt den Typ selbst (SCHRITT 1 wie bisher).
- Im Anreicherungs-Dialog (`_EnrichOptionsDialog`) optionales **Dropdown „Struktur-Typ"**
  (Auto + die Vorlagennamen). Gewählter Typ überspringt die Erkennung und erzwingt das Gerüst.

### Robustheit (bewusst eng gehalten)
- **Nur die Gerüste/Struktur** sind editierbar — die feste Präambel, Regeln und der
  Abschluss („Gib NUR die fertige Markdown-Notiz aus …") bleiben im Code.
- Inhalt/Meta werden weiterhin **vom Code** eingesetzt; der Nutzer hantiert **nicht** mit
  Platzhaltern wie `{CONTENT}` → keine kaputten Prompts möglich.

---

## Technische Umsetzung

### A — Modell + Persistenz
- **Neu** `lib/services/ai/structure_template.dart`:
  - `StructureTemplate { id, name, skeleton }` mit `toJson/fromJson/copyWith`.
  - `static List<StructureTemplate> get defaults` — die 7 heutigen Gerüste, 1:1 aus dem
    aktuellen Prompt extrahiert (verhaltensgleich).
- `AppSettings` (`lib/services/app_settings.dart`):
  - `loadStructureTemplates() / saveStructureTemplates(list)` (JSON-StringList, Fallback = defaults).
  - `getResearchStructure() / saveResearchStructure(text)` (Default = aktuelle STRUKTUR-Konstante).

### B — Prompt-Bau aus Vorlagen (`lib/services/openrouter_service.dart`)
- `generateStructuredNote(..., {List<StructureTemplate>? templates, String? forcedType})`:
  feste Präambel/Regeln/Schluss bleiben; **SCHRITT 1** (Typliste) und **SCHRITT 2** (Gerüste)
  werden aus `templates` (sonst `StructureTemplate.defaults`) gebaut. `forcedType != null` →
  SCHRITT 1 überspringen, direkt „Strukturiere als <Typ>" + dessen Gerüst.
- `generateResearchedNote(..., {String? structure})`: STRUKTUR-Sektion aus `structure`
  (sonst Default-Konstante); Regeln/Meta/Recherche-Scaffold bleiben fest.

### C — Settings-UI (`lib/features/settings/settings_screen.dart`)
- Neue Sektion **„KI-STRUKTUR-VORLAGEN"** (analog `_TemplatesSection`):
  - Strukturierte Notiz: Liste der Typ-Vorlagen (Name + „Bearbeiten" → Multiline-Editor),
    Hinzufügen/Löschen, „Auf Standard zurücksetzen".
  - Recherchierte Notiz: Multiline-Editor für die Struktur + Reset.

### D — Auslöser / Call-Sites (`lib/features/entry_detail/entry_detail_screen.dart`)
- `_EnrichOptionsDialog`: bei „strukturierte Notiz" das Dropdown „Struktur-Typ" (Auto +
  Vorlagennamen); Ergebnis als `forcedType` durchreichen.
- `_enrichWithAi` → `generateStructuredNote(..., templates: AppSettings.loadStructureTemplates(),
  forcedType: opts.forcedType)`.
- `_researchLink` → `generateResearchedNote(..., structure: AppSettings.getResearchStructure())`.

---

## Kritische Dateien
- **Neu:** `lib/services/ai/structure_template.dart`.
- **Ändern:** `lib/services/app_settings.dart`, `lib/services/openrouter_service.dart`,
  `lib/features/settings/settings_screen.dart`, `lib/features/entry_detail/entry_detail_screen.dart`.
- **Wiederverwenden:** `PropTemplate` + `_TemplatesSection`/`_TemplateEditor`-Muster,
  `AppSettings`-JSON-Listen-Persistenz, `AiService.runForTask`-Aufrufpfad.

## Migration & Kompatibilität
- Ohne gespeicherte Vorlagen werden die Defaults genutzt → bestehende Strukturierung und
  Recherche verhalten sich **unverändert**. Keine DB-Migration nötig (reine SharedPreferences).

## Verifikation
- `flutter analyze` sauber; Unit-Tests: Prompt-Builder erzeugt aus Default-Vorlagen den
  erwarteten Typblock; `forcedType` setzt den richtigen Abschnitt; JSON-Roundtrip +
  Defaults-Fallback; Recherche-Struktur-Einsetzung.
- Geräte-Test (CI-APK): REZEPT-Gerüst in Einstellungen ändern → bei Rezept-YouTube nutzt
  „strukturierte Notiz" die geänderte Struktur; „Typ erzwingen = Rezept" erzwingt das Gerüst
  auf beliebigem Inhalt; Recherche-Notiz nutzt die editierte Struktur; ohne Änderungen
  identisches Verhalten wie bisher.

## Offen / Später
- Allgemeine Regeln/Präambel bleiben bewusst fest (kann später als „Erweitert" geöffnet werden).
- Optional: Vorlagen ins Settings-Sync-Bundle (#39) aufnehmen, damit Geräte dieselben
  Gerüste teilen — als eigener kleiner Folgeschritt.
