import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/secure_storage.dart';
import 'llm_profile.dart';

const _uuid = Uuid();

final llmProfilesProvider =
    NotifierProvider<LlmProfilesNotifier, LlmProfilesState>(
        LlmProfilesNotifier.new);

class LlmProfilesState {
  final List<LlmProfile> profiles;
  final String? defaultProfileId;
  final LlmTaskAssignment taskAssignment;
  final bool aiEnabled;
  final bool loaded;

  const LlmProfilesState({
    this.profiles = const [],
    this.defaultProfileId,
    this.taskAssignment = const LlmTaskAssignment(),
    this.aiEnabled = true,
    this.loaded = false,
  });

  /// Aufgelöste, geordnete Profil-Kette für einen Task; Default-Profil als
  /// Schluss-Fallback, falls keine Kette gesetzt ist bzw. zur Sicherheit.
  List<LlmProfile> chainFor(LlmTask task) {
    final out = <LlmProfile>[];
    for (final id in taskAssignment.chainFor(task)) {
      final p = _byId(id);
      if (p != null) out.add(p);
    }
    final def = _byId(defaultProfileId);
    if (def != null && !out.any((p) => p.id == def.id)) out.add(def);
    return out;
  }

  LlmProfile? _byId(String? id) {
    if (id == null) return null;
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  LlmProfilesState copyWith({
    List<LlmProfile>? profiles,
    String? defaultProfileId,
    LlmTaskAssignment? taskAssignment,
    bool? aiEnabled,
    bool? loaded,
  }) =>
      LlmProfilesState(
        profiles: profiles ?? this.profiles,
        defaultProfileId: defaultProfileId ?? this.defaultProfileId,
        taskAssignment: taskAssignment ?? this.taskAssignment,
        aiEnabled: aiEnabled ?? this.aiEnabled,
        loaded: loaded ?? this.loaded,
      );
}

class LlmProfilesNotifier extends Notifier<LlmProfilesState> {
  static const _kProfiles = 'llm_profiles';
  static const _kDefault = 'llm_default_profile';
  static const _kTask = 'llm_task_assignment';
  static const _kAiEnabled = 'llm_ai_enabled';
  static const _kMigrated = 'llm_migrated_from_openrouter';

  @override
  LlmProfilesState build() {
    _load();
    return const LlmProfilesState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    var profiles = (prefs.getStringList(_kProfiles) ?? [])
        .map((s) {
          try {
            return LlmProfile.fromJson(jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<LlmProfile>()
        .toList();
    var defaultId = prefs.getString(_kDefault);
    final taskRaw = prefs.getString(_kTask);
    var assignment = taskRaw != null
        ? LlmTaskAssignment.fromJson(jsonDecode(taskRaw) as Map<String, dynamic>)
        : const LlmTaskAssignment();
    final aiEnabled = prefs.getBool(_kAiEnabled) ?? true;

    // Einmalige Migration: bestehenden OpenRouter-Key/-Modell als Default-Profil.
    if (!(prefs.getBool(_kMigrated) ?? false) && profiles.isEmpty) {
      final legacyKey = await secureRead('openrouter_api_key');
      if (legacyKey != null && legacyKey.isNotEmpty) {
        final legacyModel = await secureRead('openrouter_model');
        final p = LlmProfile.openRouter(_uuid.v4(),
            model: (legacyModel != null && legacyModel.isNotEmpty)
                ? legacyModel
                : 'meta-llama/llama-3.3-8b-instruct:free')
          .copyWith(hasApiKey: true);
        await secureWrite(p.keyRef, legacyKey);
        profiles = [p];
        defaultId = p.id;
        await prefs.setStringList(
            _kProfiles, profiles.map((e) => jsonEncode(e.toJson())).toList());
        await prefs.setString(_kDefault, defaultId);
      }
      await prefs.setBool(_kMigrated, true);
    }

    state = LlmProfilesState(
      profiles: profiles,
      defaultProfileId: defaultId,
      taskAssignment: assignment,
      aiEnabled: aiEnabled,
      loaded: true,
    );
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _kProfiles,
      state.profiles.map((p) => jsonEncode(p.toJson())).toList(),
    );
    if (state.defaultProfileId != null) {
      await prefs.setString(_kDefault, state.defaultProfileId!);
    } else {
      await prefs.remove(_kDefault);
    }
    await prefs.setString(_kTask, jsonEncode(state.taskAssignment.toJson()));
    await prefs.setBool(_kAiEnabled, state.aiEnabled);
  }

  // ── CRUD ─────────────────────────────────────────────────────────────────

  Future<LlmProfile> addProfile(LlmProfile profile) async {
    state = state.copyWith(
      profiles: [...state.profiles, profile],
      defaultProfileId: state.defaultProfileId ?? profile.id,
    );
    await _persist();
    return profile;
  }

  Future<void> updateProfile(LlmProfile profile) async {
    state = state.copyWith(
      profiles:
          state.profiles.map((p) => p.id == profile.id ? profile : p).toList(),
    );
    await _persist();
  }

  Future<void> deleteProfile(String id) async {
    final chains = {
      for (final t in LlmTask.values)
        t: state.taskAssignment.chainFor(t).where((x) => x != id).toList()
    };
    state = state.copyWith(
      profiles: state.profiles.where((p) => p.id != id).toList(),
      defaultProfileId:
          state.defaultProfileId == id ? null : state.defaultProfileId,
      taskAssignment: LlmTaskAssignment(chains),
    );
    await secureDelete('llm_profile_${id}_apikey');
    await _persist();
  }

  Future<void> setDefault(String id) async {
    state = state.copyWith(defaultProfileId: id);
    await _persist();
  }

  Future<void> setChain(LlmTask task, List<String> profileIds) async {
    state =
        state.copyWith(taskAssignment: state.taskAssignment.withChain(task, profileIds));
    await _persist();
  }

  Future<void> setAiEnabled(bool v) async {
    state = state.copyWith(aiEnabled: v);
    await _persist();
  }

  // ── API-Keys (Secure-Storage) ──────────────────────────────────────────────

  Future<void> saveApiKey(String profileId, String key) async {
    await secureWrite('llm_profile_${profileId}_apikey', key);
    final p = state.profiles.firstWhere((p) => p.id == profileId);
    await updateProfile(p.copyWith(hasApiKey: key.isNotEmpty));
  }

  Future<String?> loadApiKey(String profileId) =>
      secureRead('llm_profile_${profileId}_apikey');

  // ── Vorlagen + Schnell-Setup ────────────────────────────────────────────────

  Future<LlmProfile> addTemplate(ProviderKind kind) {
    final id = _uuid.v4();
    final p = switch (kind) {
      ProviderKind.openrouter => LlmProfile.openRouter(id),
      ProviderKind.groq => LlmProfile.groq(id),
      ProviderKind.ollama => LlmProfile.ollama(id),
      ProviderKind.lmstudio => LlmProfile.lmStudio(id),
      ProviderKind.custom => LlmProfile(
          id: id,
          name: 'Custom',
          kind: ProviderKind.custom,
          baseUrl: 'https://',
          model: ''),
    };
    return addProfile(p);
  }
}
