/// `flutter_secure_storage`-Schlüssel für die API-Keys der externen Quellen.
/// Gleiches Muster wie `openrouter_api_key`. Ohne hinterlegten Key bleibt die
/// jeweilige Quelle inaktiv bzw. fällt auf den generischen/oEmbed-Pfad zurück.
class ApiKeyStore {
  const ApiKeyStore._();

  static const youtube = 'youtube_api_key';
  static const tmdb = 'tmdb_api_key';
  static const omdb = 'omdb_api_key';
}
