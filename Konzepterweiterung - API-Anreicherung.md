# Konzepterweiterung: Katalog-getriebene API-Anreicherung

*Erarbeitet: 2026-06-12*

---

## Kernidee

Jede externe Datenquelle (AniList, BGG, GitHub, YouTube, TMDB, OMDb, OpenLibrary, Amazon, generisches Web) beschreibt ihre **verfügbaren Felder einmal zentral** in einem **Feld-Katalog**. Aus diesem Katalog wird automatisch dreierlei erzeugt:

1. die **Einstellungen-UI** (welche Felder standardmäßig importiert werden),
2. eine **Vorschau beim Abholen** (an-/abwählen, überschreiben, ergänzen — pro Eintrag),
3. der **Import** in den Eintrag (dedizierte Spalte oder generische Property).

Neue Quellen oder Felder kommen durch **reines Eintragen in den Katalog** dazu — keine neue Bool-Flag-, Parameter- oder UI-Verdrahtung mehr.

Zusätzlich bekommt die **KI immer den vollen Feld-Satz** einer Quelle (auch nicht-importierte Felder), damit sie diese in generierte Fließtexte einfließen lassen kann.

---

## Warum (Problem heute)

Das bestehende Modell ist starr und blockiert genau diese Wünsche:

- `UrlMetadata` hat **fest verdrahtete** Felder pro Quelle (anilistFormat, githubStars …).
- `ApiFieldSettings` ist eine **Bool-Explosion** — jedes Feld = ein `bool` + copyWith/toJson/fromJson-Zeile.
- Der Import ist **handgeschriebenes per-Feld-Gating** über dutzende benannte `createEntry`-Parameter.

„Alle Felder jeder API auswählbar" + 4 neue Quellen würden in diesem Modell zu hunderten Flags/Parametern führen — unwartbar.

---

## Kern-Abstraktionen (`lib/services/enrichment/`)

- **`ApiSource`** (enum): `anilist, bgg, vgg, rpgg, github, youtube, tmdbMovie, tmdbTv, omdb, openLibrary, amazon, genericWeb`.
- **`ApiFieldDef`** `{ key, label, PropType type, group?, column? }`
  - `type` nutzt das vorhandene `PropType`.
  - `column` = optionale dedizierte Drift-Spalte (Abwärtskompatibilität der Feed-Karten); fehlt sie, wird das Feld eine generische `EntryProperty`.
- **`ApiFieldCatalog`**: `Map<ApiSource, List<ApiFieldDef>>` — die **eine Quelle der Wahrheit**.
- **`MetadataRecord`** `{ source, url, title, Map<String,dynamic> fields, List<ApiSource> alternativeSources }`
  - `fields` keyed nach Katalog-Keys; Bilder/Cover sind Felder vom Typ `image`/`url`.
  - `alternativeSources` z.B. Film: `[tmdbMovie, omdb]` → Quellenwahl beim Abholen.

---

## Features im Überblick

### Vorschau beim Abholen (`FieldImportSheet`)

Nach dem Abruf erscheint ein Sheet mit **allen** gefundenen Feldern:

- Checkbox je Feld, vorbelegt aus den Einstellungen-Defaults.
- Wert **inline editierbar** (überschreiben) + Zeile **„Feld hinzufügen"** (eigene Felder).
- Bilder/Cover als **Thumbnail-Vorschau**.
- Quellen-Umschalter bei mehreren möglichen Quellen (z.B. TMDB ↔ OMDb), der neu abruft.
- Bestätigen → nur die gewählten Felder werden importiert.

### Generischer Import

Gewählte Felder werden generisch geschrieben: hat das Feld eine `column`, füllt es die dedizierte Spalte (Karten bleiben kompatibel), sonst wird es eine `EntryProperty` (key = Label, type = FieldDef.type).

### KI mit vollem Kontext

Die KI-Anreicherung (`enrichEntry`, `generateResearchedNote`, `generateStructuredNote`) erhält den **kompletten** `record.fields`-Satz als Kontextblock — unabhängig davon, was importiert wurde. So kann die KI auch nicht-importierte Felder in Texte einweben.

### Einstellungen aus dem Katalog

Die API-Feld-Einstellungen werden **dynamisch aus dem Katalog** gerendert: pro Quelle eine Gruppe mit Checkboxen. Dazu API-Key-Felder (YouTube / TMDB / OMDb) in `flutter_secure_storage`.

### Neue Quellen

| Quelle | Key | Felder (Auszug) |
|---|---|---|
| YouTube Data API v3 | ja | Kanal, Dauer, Views, Likes, Datum, Tags, Beschreibung, Thumbnail |
| TMDB (Film/Serie) | ja | Overview, Genres, Cast, Laufzeit, Release, Rating, Poster/Backdrop |
| OMDb (Film/Serie) | ja | Plot, Director, Actors, Genre, Runtime, imdbRating, Poster |
| OpenLibrary (Bücher) | nein | Autor(en), Seiten, Erstveröffentlichung, Subjects, ISBN, Cover |
| Amazon/Shop | nein | best-effort über OG/HTML (Titel, Bild, Preis) + KI; fragil |
| Generisches Web | nein | HTML-Volltext → KI-Anreicherung (#27) |

---

## Umsetzungsphasen

- **Phase 0 — Fundament:** Kern-Abstraktionen, Katalog der Bestandsquellen, Records aus den Extraktoren, `ApiFieldPrefs` + Migration aus `ApiFieldSettings`, Key-Storage. Keine UX-Änderung.
- **Phase 1 — Vorschau & Import:** `FieldImportSheet`, generischer Import, katalog-getriebene Settings-UI.
- **Phase 2 — KI-Vollkontext:** voller Feld-Satz an die KI.
- **Phase 3 — YouTube Data API.**
- **Phase 4 — TMDB + OMDb (wählbar).**
- **Phase 5 — OpenLibrary.**
- **Phase 6 — Amazon/Shop best-effort + generische Link-KI + tiefere Bestands-Extraktoren.**

Reihenfolge: erst **0–2** als erstes Release (realisiert die Kern-Vision schon für die Bestandsquellen), danach quellenweise 3–6.

---

## Kompatibilität & Migration

- Bestehende `ApiFieldSettings`-Bools werden beim ersten Laden **automatisch** in `ApiFieldPrefs` migriert — bestehende Auswahl bleibt unverändert wirksam.
- Dedizierte Drift-Spalten (anilist*, github*, urlScore …) bleiben erhalten; der Katalog mappt die jeweiligen Felder per `column` darauf. Feed-Karten bleiben unangetastet.
- Fehlt ein API-Key, bleibt die Quelle inaktiv bzw. fällt auf den generischen/oEmbed-Pfad zurück.

---

## Verifikation

- `flutter analyze` sauber; Unit-Tests für Katalog↔Record-Mapping und die `ApiFieldSettings`→`ApiFieldPrefs`-Migration.
- Geräte-Test (CI-Debug-APK): Link je Quelle abholen → Vorschau zeigt Felder + Cover → Auswahl/Override/Ergänzen → Import prüfen (Properties + Karten). KI: nicht-importiertes Feld taucht im Text auf. Migration: Settings nach Update unverändert.
