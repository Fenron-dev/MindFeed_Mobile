import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../openrouter_service.dart';
import 'llm_profile.dart';
import 'llm_profiles_store.dart';

/// Führt KI-Operationen entlang der **Fallback-Kette** eines Vorgangs aus:
/// versucht Profil für Profil, bis eines liefert. Limitierte Profile werden in
/// einen In-Memory-Cooldown gelegt (bezahlte ausgenommen).
class AiService {
  AiService._();

  static const _kCooldownMin = 'llm_cooldown_minutes';
  static const _defaultCooldownMinutes = 10;

  /// profileId → Zeitpunkt, bis zu dem das Profil übersprungen wird.
  static final Map<String, DateTime> _cooldownUntil = {};

  static Future<int> cooldownMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kCooldownMin) ?? _defaultCooldownMinutes;
  }

  static Future<void> setCooldownMinutes(int m) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kCooldownMin, m);
  }

  static bool _inCooldown(String id) {
    final until = _cooldownUntil[id];
    if (until == null) return false;
    if (until.isAfter(DateTime.now())) return true;
    _cooldownUntil.remove(id);
    return false;
  }

  /// Führt [op] am ersten verfügbaren Profil der Kette von [task] aus.
  /// [onNotice] meldet z.B. einen automatischen Modellwechsel (für SnackBar).
  static Future<T> runForTask<T>(
    WidgetRef ref,
    LlmTask task,
    Future<T> Function(OpenRouterService client) op, {
    void Function(String notice)? onNotice,
  }) async {
    final state = ref.read(llmProfilesProvider);
    if (!state.aiEnabled) {
      throw Exception('KI ist in den Einstellungen deaktiviert.');
    }
    final chain = state.chainFor(task);
    if (chain.isEmpty) {
      throw Exception(
          'Kein KI-Profil für „${task.label}" zugewiesen. Bitte in den Einstellungen festlegen.');
    }
    final notifier = ref.read(llmProfilesProvider.notifier);
    final defaultCooldown = Duration(minutes: await cooldownMinutes());
    final errors = <String>[];

    for (var i = 0; i < chain.length; i++) {
      final p = chain[i];
      // Freie Profile im Cooldown überspringen; bezahlte bleiben verfügbar.
      if (p.tier == LlmTier.free && _inCooldown(p.id)) {
        errors.add('${p.name}: im Cooldown');
        continue;
      }
      final key = await notifier.loadApiKey(p.id) ?? '';
      if (p.needsApiKey && key.isEmpty) {
        errors.add('${p.name}: kein API-Key hinterlegt');
        continue;
      }
      final client = OpenRouterService(
        apiKey: key,
        model: p.model,
        temperature: p.temperature,
        maxTokens: p.maxTokens,
        chatUrl: p.chatUrl,
      );
      try {
        final result = await op(client);
        if (i > 0) {
          onNotice?.call('„${chain[i - 1].name}" nicht verfügbar → „${p.name}" genutzt.');
        }
        return result;
      } on AiUnavailableException catch (e) {
        errors.add('${p.name}: ${e.message}');
        if (e.isLimit) {
          _cooldownUntil[p.id] =
              DateTime.now().add(e.retryAfter ?? defaultCooldown);
        }
        // weiter zum nächsten Kettenglied
      } catch (e) {
        // z.B. ungültige Antwort (kein JSON), Netzfehler → nächstes Profil.
        errors.add('${p.name}: $e');
      }
    }
    throw Exception('Alle KI-Profile fehlgeschlagen:\n${errors.join('\n')}');
  }
}
