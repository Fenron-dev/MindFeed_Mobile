import '../../core/secure_storage.dart';
import '../app_settings.dart';
import 'brave_provider.dart';
import 'searxng_provider.dart';
import 'web_search_provider.dart';

export 'brave_provider.dart';
export 'searxng_provider.dart';
export 'web_search_provider.dart';

/// Baut einen Provider aus Art + Konfigurationswert (URL bzw. API-Key).
/// Liefert `null`, wenn der Konfigurationswert leer ist.
WebSearchProvider? buildWebSearchProvider(
    WebSearchProviderKind kind, String config) {
  final value = config.trim();
  if (value.isEmpty) return null;
  switch (kind) {
    case WebSearchProviderKind.searxng:
      return SearxngProvider(baseUrl: value);
    case WebSearchProviderKind.brave:
      return BraveProvider(apiKey: value);
  }
}

/// Löst den in den Einstellungen aktiven Recherche-Provider auf (inkl. dessen
/// im Secure-Storage hinterlegter Konfiguration). Liefert `null`, wenn kein
/// Provider konfiguriert ist (z. B. fehlende URL/Key).
Future<WebSearchProvider?> resolveActiveWebSearchProvider() async {
  final kind = WebSearchProviderKind.fromId(AppSettings.getWebSearchProvider());
  final config = (await secureRead(kind.secureKey) ?? '').trim();
  return buildWebSearchProvider(kind, config);
}
