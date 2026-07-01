/// Ein einzelner Web-Recherche-Treffer (provider-unabhängig).
class WebSearchResult {
  final String title;
  final String url;
  final String content; // Snippet/Beschreibung
  const WebSearchResult({
    required this.title,
    required this.url,
    required this.content,
  });
}

/// Gemeinsame Schnittstelle für Web-Recherche-Anbieter (SearXNG, Brave …).
///
/// Liefert Treffer-Snippets, die der KI-Anreicherung als Kontext dienen, damit
/// das LLM Abschnitte wie Alternativen/Referenzen/FAQ nicht halluziniert (#32).
abstract class WebSearchProvider {
  /// Führt eine Suche aus und liefert bis zu [limit] Treffer.
  Future<List<WebSearchResult>> search(
    String query, {
    String language,
    int limit,
  });

  /// Prüft die Verbindung/Konfiguration. Liefert `null` bei Erfolg, sonst eine
  /// menschenlesbare Fehlermeldung.
  Future<String?> testConnection();
}

/// Verfügbare Recherche-Anbieter. Treibt zugleich die Einstellungs-UI
/// (Label, Konfig-Feld) und den Resolver.
enum WebSearchProviderKind {
  /// Selbst gehostete SearXNG-Instanz (Basis-URL, kein Geheimnis im engeren
  /// Sinne — wird wie bisher in den Sync-Bundle übernommen).
  searxng(
    id: 'searxng',
    label: 'SearXNG (eigene Instanz)',
    configLabel: 'Basis-URL',
    configHint: 'http://192.168.x.x:8080',
    secureKey: 'searxng_base_url',
    isSecret: false,
  ),

  /// Brave Search API (API-Key). Cloud-Suche ohne Self-Hosting.
  brave(
    id: 'brave',
    label: 'Brave Search API',
    configLabel: 'API-Key',
    configHint: 'BSA…',
    secureKey: 'brave_api_key',
    isSecret: true,
  );

  const WebSearchProviderKind({
    required this.id,
    required this.label,
    required this.configLabel,
    required this.configHint,
    required this.secureKey,
    required this.isSecret,
  });

  /// Stabiler Schlüssel für die Persistenz in den Einstellungen.
  final String id;

  /// Anzeigename in der UI.
  final String label;

  /// Beschriftung des Konfig-Eingabefelds (URL bzw. API-Key).
  final String configLabel;

  /// Platzhalter im Konfig-Eingabefeld.
  final String configHint;

  /// Secure-Storage-Schlüssel, unter dem die Konfiguration liegt.
  final String secureKey;

  /// Ob die Konfiguration ein Geheimnis (API-Key) ist → nicht in den
  /// Geräte-Sync-Bundle übernehmen, Eingabefeld verschleiern.
  final bool isSecret;

  static WebSearchProviderKind fromId(String? id) =>
      values.firstWhere((e) => e.id == id, orElse: () => searxng);
}

/// Verdichtet Treffer zu einem nummerierten Kontextblock fürs LLM.
String webResultsToContext(List<WebSearchResult> results) {
  final sb = StringBuffer();
  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    sb.writeln('[${i + 1}] ${r.title}');
    if (r.content.isNotEmpty) sb.writeln(r.content);
    sb.writeln(r.url);
    sb.writeln();
  }
  return sb.toString().trim();
}
