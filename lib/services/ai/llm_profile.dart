// LLM-Provider-Profile (nach Vorbild OracleVault, angepasst an MindFeed).
//
// Ein Profil = OpenAI-kompatibler Endpoint + Modell + Parameter (+ optional Key).
// Alle Anbieter (OpenRouter, Groq, Ollama, LM Studio, custom) teilen das
// `/chat/completions`-Interface → ein HTTP-Client genügt.
//
// API-KEYS liegen NICHT im Profil-JSON, sondern im Secure-Storage unter [keyRef].

enum ProviderKind { openrouter, groq, ollama, lmstudio, custom }

extension ProviderKindX on ProviderKind {
  String get label => switch (this) {
        ProviderKind.openrouter => 'OpenRouter',
        ProviderKind.groq => 'Groq',
        ProviderKind.ollama => 'Ollama (lokal)',
        ProviderKind.lmstudio => 'LM Studio (lokal)',
        ProviderKind.custom => 'Custom',
      };

  /// Lokale Anbieter senden keine Daten in die Cloud.
  bool get isLocalKind =>
      this == ProviderKind.ollama || this == ProviderKind.lmstudio;
}

enum LlmTier { free, paid }

/// KI-Vorgänge, denen je eine Profil-Kette zugewiesen wird.
enum LlmTask { enrichment, structuredNote, researchedNote, vision }

extension LlmTaskX on LlmTask {
  String get label => switch (this) {
        LlmTask.enrichment => 'Anreicherung (Tags/Titel/Summary)',
        LlmTask.structuredNote => 'Strukturierte Notiz',
        LlmTask.researchedNote => 'Recherchierte Notiz',
        LlmTask.vision => 'Bild-Analyse (Vision)',
      };
}

/// Ein KI-Provider-Profil.
class LlmProfile {
  final String id;
  final String name;
  final ProviderKind kind;

  /// OpenAI-kompatible Basis-URL, z.B. `https://openrouter.ai/api/v1`.
  /// Daraus leiten sich [chatUrl] und [modelsUrl] ab.
  final String baseUrl;
  final String model;
  final double temperature;
  final int maxTokens;
  final bool hasApiKey;
  final LlmTier tier;
  final bool isLocal;

  /// Best-effort-Flag, ob das gewählte Modell Bilder versteht (für den
  /// Vision-Task-Picker). Wird beim Modell-Wählen gesetzt, manuell überschreibbar.
  final bool supportsVision;

  const LlmProfile({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.model,
    this.temperature = 0.3,
    this.maxTokens = 800,
    this.hasApiKey = false,
    this.tier = LlmTier.free,
    this.isLocal = false,
    this.supportsVision = false,
  });

  String get keyRef => 'llm_profile_${id}_apikey';
  String get chatUrl => '${_base()}/chat/completions';
  String get modelsUrl => '${_base()}/models';
  String _base() =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  /// Braucht dieser Provider zwingend einen API-Key? (Lokale nicht.)
  bool get needsApiKey => !isLocal;

  LlmProfile copyWith({
    String? name,
    ProviderKind? kind,
    String? baseUrl,
    String? model,
    double? temperature,
    int? maxTokens,
    bool? hasApiKey,
    LlmTier? tier,
    bool? isLocal,
    bool? supportsVision,
  }) =>
      LlmProfile(
        id: id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        temperature: temperature ?? this.temperature,
        maxTokens: maxTokens ?? this.maxTokens,
        hasApiKey: hasApiKey ?? this.hasApiKey,
        tier: tier ?? this.tier,
        isLocal: isLocal ?? this.isLocal,
        supportsVision: supportsVision ?? this.supportsVision,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'base_url': baseUrl,
        'model': model,
        'temperature': temperature,
        'max_tokens': maxTokens,
        'has_api_key': hasApiKey,
        'tier': tier.name,
        'is_local': isLocal,
        'supports_vision': supportsVision,
      };

  factory LlmProfile.fromJson(Map<String, dynamic> j) {
    final kind = ProviderKind.values.asNameMap()[j['kind'] as String? ?? ''] ??
        ProviderKind.custom;
    return LlmProfile(
      id: j['id'] as String,
      name: j['name'] as String,
      kind: kind,
      baseUrl: j['base_url'] as String,
      model: (j['model'] as String?) ?? '',
      temperature: (j['temperature'] as num?)?.toDouble() ?? 0.3,
      maxTokens: (j['max_tokens'] as int?) ?? 800,
      hasApiKey: (j['has_api_key'] as bool?) ?? false,
      tier: LlmTier.values.asNameMap()[j['tier'] as String? ?? ''] ??
          LlmTier.free,
      isLocal: (j['is_local'] as bool?) ?? kind.isLocalKind,
      supportsVision: (j['supports_vision'] as bool?) ?? false,
    );
  }

  // ── Vorlagen ───────────────────────────────────────────────────────────────

  static LlmProfile openRouter(String id,
          {String model = 'meta-llama/llama-3.3-8b-instruct:free'}) =>
      LlmProfile(
        id: id,
        name: 'OpenRouter',
        kind: ProviderKind.openrouter,
        baseUrl: 'https://openrouter.ai/api/v1',
        model: model,
      );

  static LlmProfile groq(String id,
          {String model = 'llama-3.3-70b-versatile'}) =>
      LlmProfile(
        id: id,
        name: 'Groq',
        kind: ProviderKind.groq,
        baseUrl: 'https://api.groq.com/openai/v1',
        model: model,
      );

  static LlmProfile ollama(String id, {String model = 'llama3.2'}) => LlmProfile(
        id: id,
        name: 'Ollama (lokal)',
        kind: ProviderKind.ollama,
        baseUrl: 'http://localhost:11434/v1',
        model: model,
        isLocal: true,
      );

  static LlmProfile lmStudio(String id, {String model = 'local-model'}) =>
      LlmProfile(
        id: id,
        name: 'LM Studio (lokal)',
        kind: ProviderKind.lmstudio,
        baseUrl: 'http://localhost:1234/v1',
        model: model,
        isLocal: true,
      );
}

/// Ordnet jedem [LlmTask] eine **geordnete Profil-Kette** zu (Fallback-Reihenfolge).
/// Leere Kette → Fallback auf das Default-Profil.
class LlmTaskAssignment {
  final Map<LlmTask, List<String>> chains;

  const LlmTaskAssignment([this.chains = const {}]);

  List<String> chainFor(LlmTask task) => chains[task] ?? const [];

  LlmTaskAssignment withChain(LlmTask task, List<String> profileIds) {
    final next = {for (final e in chains.entries) e.key: e.value};
    next[task] = profileIds;
    return LlmTaskAssignment(next);
  }

  Map<String, dynamic> toJson() =>
      {for (final e in chains.entries) e.key.name: e.value};

  factory LlmTaskAssignment.fromJson(Map<String, dynamic> j) {
    final map = <LlmTask, List<String>>{};
    final byName = LlmTask.values.asNameMap();
    j.forEach((k, v) {
      final task = byName[k];
      if (task != null && v is List) {
        map[task] = v.map((e) => '$e').toList();
      }
    });
    return LlmTaskAssignment(map);
  }
}
