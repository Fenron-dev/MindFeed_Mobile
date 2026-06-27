# Konzepterweiterung: LLM-Profile, Fallback-Ketten & KI-Notiz aus Bild

*Erarbeitet: 2026-06-26*

---

## Kernidee

Statt eines fest verdrahteten Anbieters („ein Key + ein Modell") gibt es **bearbeitbare LLM-Profile**. Jedes Profil = Provider/Endpoint + Modell + Parameter + (optional) API-Key. Pro **Anwendungsfall** (Anreicherung, strukturierte Notiz, Recherche, **Vision/Bild**) wählt der Nutzer eine **geordnete Profil-Kette** — wird das bevorzugte Modell limitiert/unerreichbar, rückt **automatisch** das nächste nach. Einmal Präferenzen hinterlegen, immer die beste Erfahrung, ohne in die Einstellungen zu müssen.

Zusätzlich: **Bild → Notiz.** Ein Screenshot/Foto wird von einem **Vision-Modell** analysiert (welche Seite/Medium, worum geht es) und in eine Notiz verwandelt — auch wenn kein Link teilbar/sichtbar ist.

Design-Vorbild für die Profile: das Schwesterprojekt **OracleVault** (`lib/services/llm/llm_profile.dart`, `llm_profiles_store.dart`).

---

## Features im Überblick

### LLM-Profile
- Felder: `name, kind, baseUrl, defaultModel, temperature, maxTokens, hasApiKey, tier(frei|bezahlt), isLocal`.
- Anbieter (`ProviderKind`): **OpenRouter**, **Groq** (neu, OpenAI-kompatibel, freie Modelle), **Ollama/LM Studio** (lokal), **custom**.
- **Capability-Tags/Icons** (wo möglich automatisch): **Vision**, **Frei/Bezahlt**, **Lokal**.
- API-Keys getrennt im Secure-Storage (nicht im Profil-JSON).
- **Profil-Test**-Button (Endpoint + Key + Modell prüfen).
- **Schnell-Setup**: 1-Tap-Vorlage „Free-Mix" (mehrere freie OpenRouter-Modelle + ein freies Groq-Modell als fertige Fallback-Kette).

### Anwendungsfall-Picker mit Reihenfolge
- Pro Vorgang (Anreicherung / strukturierte Notiz / Recherche / Vision) werden Profile **ausgewählt und geordnet** = Fallback-Kette.
- Default-Profil als Schluss-Fallback.

### Fallback-Ketten (Auto-Wechsel)
- **Reaktiv** (kein Vortest vor jeder Anfrage — das kostet Zeit und zählt selbst aufs Limit): normal anfragen, bei Fehler weiterrücken.
- **Auslöser**: HTTP 429 (Limit), 402 (kein Guthaben), 404 (Modell weg), 5xx, Timeout, sowie leere/ungültige Antwort.
- **Cooldown, header-bewusst**: limitiertes Profil wird übersprungen; Dauer aus `Retry-After`/Reset-Headern → kurz bei Minuten-Limit, lang (bis ~nächster Tag) bei Tageslimit. Default-Dauer einstellbar.
- **Tier-bewusst**: bezahlte Profile (mit Guthaben) werden nicht vorsorglich übersprungen (zuverlässiges Ketten-Ende); erst ein 402 legt sie schlafen.
- **Transparenz**: dezenter Hinweis (SnackBar), wenn auf ein Ersatzmodell gewechselt wurde.

### KI-Notiz aus Bild (Vision)
- `analyzeImage`: Bild auf ~1024px verkleinern → Base64 → multimodaler Request (`image_url`).
- Erkennt Quelle/Medium **und** Titel **und** Inhalt → JSON (Titel/Zusammenfassung/Tags + erkannter Titel/Medientyp).
- **Vision-Filter** im Modell-Picker (beide Anbieter): OpenRouter über `architecture.input_modalities`, Groq über Namens-/Allowlist-Heuristik.
- **Bestätigung/Korrektur**: erkannter Titel wird angezeigt → Übernehmen / Bearbeiten / Verwerfen.
- Bei Übernahme **echte Metadaten**: AniList-Titelsuche (jetzt) → Cover/Genres etc.; Film/Serie folgt mit TMDB/OMDb.
- **Einstiegspunkte**: beim Erfassen (Foto/Screenshot → „KI aus Bild") und in bestehender Notiz mit Bild-Anhang (⋮-Menü).

### Datenschutz & Schalter
- **Datenschutz-Hinweis** bei Cloud-Profil für Bild/sensible Inhalte („Inhalte verlassen das Gerät").
- **Globaler AI-an/aus**-Schalter.

---

## Migration & Kompatibilität
- Vorhandener OpenRouter-Key/-Modell → einmalig als **Default-OpenRouter-Profil** übernommen. Bestehende Anreicherung verhält sich unverändert.
- Die 5 bisherigen Service-Konstruktionen (`settings`, `capture`, `entry_detail`×2, `bulk_action_bar`) laufen künftig über einen zentralen `AiService.runForTask` mit Fallback.

---

## Umsetzungsphasen
1. **Profile-Fundament + Fallback**: Modell + Store (Riverpod) + `AiService.runForTask` (Ketten, header-bewusster Cooldown), Migration, Settings-UI (Profil-CRUD + Test + Anwendungsfall-Picker + Schnell-Setup + Privatsphäre-Hinweis), Call-Sites umstellen — inkl. **Groq** + globaler Schalter.
2. **Vision-Filter** (beide Anbieter) im Modell-Picker.
3. **`analyzeImage` + „KI aus Bild"** (Erfassen + bestehende Notiz) + Datenschutz-Hinweis.
4. **Titel bestätigen → AniList** (+ Hinweis für Film/Serie bis TMDB/OMDb).

Jede Phase ist einzeln baubar und testbar.

---

## Verifikation
- `flutter analyze` sauber; Unit-Tests: Profil-JSON-Roundtrip + Ketten-Auflösung, Fallback-Logik (429/402/404 → nächstes Profil; Cooldown aus `Retry-After`; bezahltes Profil nicht übersprungen), Migration, Bild-Resize/Base64, Vision-JSON-Parsing, AniList-Such-Mapping, Vision-Filter-Heuristik.
- Geräte-Test (CI-APK): Profile (OpenRouter + Groq) anlegen, Ketten ordnen; freies Modell ans Limit bringen → automatischer Wechsel mit SnackBar; Screenshot eines Anime/YouTube-Bildschirms → „KI aus Bild" → Titel-Dialog → Notiz mit AniList-Metadaten.

## Offen / Später
- **Sync-Konflikt-Ansicht**: nur betroffene Bereiche, side-by-side (eigenes Issue).
- Film/Serie-Metadaten aus erkanntem Titel brauchen TMDB/OMDb (separat, Keys nötig).
