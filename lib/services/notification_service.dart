import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static bool _available = true; // false, wenn Init auf der Plattform scheitert
  static bool _exactAlarms = true; // false → Fallback auf inexakte Planung

  /// Initialisiert die Notifications plattformsicher. Fehler werden gefangen,
  /// damit ein fehlendes/instabiles Backend (z.B. Windows ohne gültige
  /// Konfiguration) niemals den App-Start blockiert.
  static Future<void> init() async {
    if (_initialized || !_available) return;
    try {
      tz_data.initializeTimeZones();
      // Geräte-Zeitzone setzen, sonst bleibt tz.local = UTC und zonedSchedule
      // feuert um den UTC-Offset (und DST) versetzt.
      try {
        final info = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(info.identifier));
      } catch (e) {
        debugPrint('[Notifications] Zeitzone konnte nicht gesetzt werden: $e');
      }

      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      // Windows benötigt eigene Settings (fester GUID für die App).
      const windows = WindowsInitializationSettings(
        appName: 'MindFeed',
        appUserModelId: 'dev.fenron.mindfeed',
        guid: 'a3f1c2d4-8b9e-4f1a-9c2d-6e7f8a9b0c1d',
      );
      await _plugin.initialize(
        const InitializationSettings(
            android: android, iOS: darwin, macOS: darwin, windows: windows),
      );

      await _requestAndroidPermissions();
      _initialized = true;
    } catch (e) {
      _available = false;
      debugPrint('[Notifications] Init fehlgeschlagen, deaktiviert: $e');
    }
  }

  /// Fordert auf Android die nötigen Runtime-Permissions an:
  /// POST_NOTIFICATIONS (ab Android 13) und exakte Alarme (ab Android 12).
  /// Wird der Exact-Alarm verweigert, fällt schedule() auf inexakte Planung
  /// zurück, statt still zu scheitern.
  static Future<void> _requestAndroidPermissions() async {
    if (!Platform.isAndroid) return;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    try {
      await android.requestNotificationsPermission();
      final canExact = await android.canScheduleExactNotifications();
      _exactAlarms = canExact ?? false;
      if (!_exactAlarms) {
        debugPrint('[Notifications] Exakte Alarme nicht erlaubt → inexakter '
            'Modus (Erinnerungen können einige Minuten verzögert sein).');
      }
    } catch (e) {
      debugPrint('[Notifications] Permission-Anfrage fehlgeschlagen: $e');
    }
  }

  static Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime when,
  }) async {
    await init();
    if (!_available) return;
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(when, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'mindfeed_reminders',
            'MindFeed Erinnerungen',
            channelDescription: 'Erinnerungen für MindFeed Einträge',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: _exactAlarms
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (e) {
      debugPrint('[Notifications] schedule fehlgeschlagen: $e');
    }
  }

  static Future<void> cancel(int id) async {
    await init();
    if (!_available) return;
    try {
      await _plugin.cancel(id);
    } catch (e) {
      debugPrint('[Notifications] cancel fehlgeschlagen: $e');
    }
  }

  // Entry-ID → Notification-ID (Hash damit es deterministisch ist)
  static int idFromEntryId(String entryId) =>
      entryId.hashCode.abs() % 100000;
}
