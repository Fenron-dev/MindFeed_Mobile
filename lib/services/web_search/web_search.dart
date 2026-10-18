import '../../core/secure_storage.dart';
import '../app_settings.dart';
import 'brave_provider.dart';
import 'parallel_provider.dart';
import 'searxng_provider.dart';
import 'web_search_provider.dart';

export 'brave_provider.dart';
export 'parallel_provider.dart';
export 'searxng_provider.dart';
export 'web_search_provider.dart';

/// Baut einen Provider aus Art + Konfigurationswert (URL bzw. API-Key).
/// Parallel benötigt keine Konfiguration. Deaktiviert liefert immer `null`.
WebSearchProvider? buildWebSearchProvider(
  WebSearchProviderKind kind,
  String config,
) {
  final value = config.trim();
  if (kind.requiresConfig && value.isEmpty) return null;
  switch (kind) {
    case WebSearchProviderKind.parallel:
      return const ParallelProvider();
    case WebSearchProviderKind.disabled:
      return null;
    case WebSearchProviderKind.searxng:
      return SearxngProvider(baseUrl: value);
    case WebSearchProviderKind.brave:
      return BraveProvider(apiKey: value);
  }
}

/// Explizite Auswahl erhalten, auch bei fehlender Konfiguration. Vor der
/// Provider-Auswahl gespeicherte Zugangsdaten bleiben ebenfalls wirksam.
Future<WebSearchProviderKind> resolveActiveWebSearchProviderKind() async {
  final saved = AppSettings.getWebSearchProvider();
  if (saved != null) return WebSearchProviderKind.fromId(saved);
  for (final kind in [
    WebSearchProviderKind.searxng,
    WebSearchProviderKind.brave,
  ]) {
    if ((await secureRead(kind.secureKey) ?? '').trim().isNotEmpty) return kind;
  }
  return WebSearchProviderKind.parallel;
}

/// Nur ohne Auswahl und ohne Alt-Konfiguration wird Parallel verwendet.
/// Deaktivierte KI darf bereits vor dem ersten Netzwerkzugriff abbrechen.
Future<WebSearchProvider?> resolveActiveWebSearchProvider({
  bool enabled = true,
}) async {
  if (!enabled) return null;
  final kind = await resolveActiveWebSearchProviderKind();
  if (!kind.requiresConfig) return buildWebSearchProvider(kind, '');
  final config = (await secureRead(kind.secureKey) ?? '').trim();
  return buildWebSearchProvider(kind, config);
}
