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

## Verwandte Projekte

- [MindFeed Web](https://github.com/Fenron-dev/MindFeed) — Node.js/React Backend + Web-App
