# App Icon

Lege hier zwei Dateien ab:

## app_icon.png
Das vollständige App-Icon (1024×1024 px, PNG).
Wird für iOS (alle Größen) und Android verwendet.

## app_icon_fg.png (optional)
Für Android Adaptive Icons: nur der Vordergrund-Teil (1024×1024 px),
ohne den dunklen Hintergrund — z.B. nur die Neon-Kugel und Verbindungslinien
auf transparentem Hintergrund.
Falls nicht vorhanden: einfach app_icon.png kopieren und umbenennen.

## Icon generieren
Nach dem Ablegen der Datei(en):
```bash
flutter pub get
flutter pub run flutter_launcher_icons
```
