# MindFeed Mobile

Offline-first Second Brain / PKM-App für iOS & Android, gebaut mit Flutter.

## Features (V1)

- Einträge erfassen mit #Tags und [[Wikilinks]]
- Links hinzufügen + AI-Analyse (YouTube, AniList, OpenGraph)
- OpenRouter.ai Integration (wählbare Modelle inkl. Free-Tier)
- Custom Properties (EAV) pro Eintrag
- Container-Struktur: Projekte / Bereiche / Smart Hubs
- FTS5 Volltextsuche
- Share Intent (URLs aus anderen Apps empfangen)
- Server-Sync via WireGuard (MindFeed Node.js Backend)
- Backup & Restore (ZIP)
- Vault-Konzept mit optionaler SQLCipher-Verschlüsselung

## Tech Stack

- Flutter 3.x / Dart 3.x
- Riverpod 2.6 (State Management)
- Drift 2.23 + SQLite (lokale Datenbank mit FTS5)
- GoRouter 14 (Navigation)
- OpenRouter.ai (AI via OpenAI-kompatibler API)

## Setup

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

## Web-Recherche für KI-Notizen

Die Aktionen **Link recherchieren (Web)** und **IT-Notiz erzeugen (KI) → Modus A** verwenden
[Parallel Search MCP](https://docs.parallel.ai/integrations/mcp/search-mcp)
im Fast-Modus, wenn noch kein Recherche-Provider und keine bisherige
SearXNG-URL bzw. kein Brave-Key hinterlegt sind. Dafür ist kein Parallel-Konto
oder API-Key nötig. Vorhandene Provider-Auswahlen und Zugangsdaten bleiben
erhalten; bei Fehlern wird der Anbieter nicht automatisch gewechselt.

Unter **Einstellungen → Web-Recherche** lassen sich Parallel, die eigene
SearXNG-Instanz, Brave Search API oder **Deaktiviert** wählen und speichern.
Der Verbindungstest für Parallel prüft die MCP-Verbindung und das Suchwerkzeug.
Erst eine gestartete Recherche sendet den Suchbegriff (Notiz-Titel bzw.
Problembeschreibung) an den gewählten Anbieter. Die Treffer mit Quell-URLs
dienen dem konfigurierten KI-Profil als Kontext. Deaktivierte KI verhindert
auch die Web-Recherche. Die kostenlose Parallel-Nutzung hat Limits; bei einem
Rate-Limit später erneut versuchen. Das bestehende KI-Profil wird weiterhin
für die Notizerstellung benötigt.

## Verwandte Projekte

- [MindFeed Web](https://github.com/Fenron-dev/MindFeed) — Node.js/React Backend + Web-App
