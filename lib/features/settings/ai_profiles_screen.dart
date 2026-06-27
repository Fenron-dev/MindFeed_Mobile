import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../services/ai/ai_service.dart';
import '../../services/ai/llm_profile.dart';
import '../../services/ai/llm_profiles_store.dart';
import '../../services/openrouter_service.dart';

/// Heuristik: ist ein OpenRouter/OpenAI-Modell-Eintrag bild-/multimodal?
bool modelSupportsVision(Map<String, dynamic> m) {
  final arch = m['architecture'];
  if (arch is Map) {
    final mods = arch['input_modalities'];
    if (mods is List && mods.map((e) => '$e').contains('image')) return true;
    final modality = '${arch['modality'] ?? ''}'.toLowerCase();
    if (modality.contains('image')) return true;
  }
  final id = '${m['id'] ?? ''}'.toLowerCase();
  return ['vision', 'scout', 'maverick', 'llama-4', 'vl', 'gemini', 'gpt-4o']
      .any(id.contains);
}

bool modelIsFree(Map<String, dynamic> m) {
  final id = '${m['id'] ?? ''}'.toLowerCase();
  if (id.endsWith(':free')) return true;
  final pricing = m['pricing'];
  if (pricing is Map) {
    return pricing.values.every((v) => v == null || v == '0' || v == 0);
  }
  return false;
}

class AiProfilesScreen extends ConsumerWidget {
  const AiProfilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(llmProfilesProvider);
    final notifier = ref.read(llmProfilesProvider.notifier);

    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        title: const Text('KI-Profile & Modelle',
            style: TextStyle(color: MFColors.textPrimary, fontSize: 17)),
        iconTheme: const IconThemeData(color: MFColors.textSecondary),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          SwitchListTile(
            value: state.aiEnabled,
            activeColor: MFColors.teal,
            contentPadding: EdgeInsets.zero,
            title: const Text('KI aktiviert',
                style: TextStyle(color: MFColors.textPrimary)),
            subtitle: const Text('Anreicherung, Recherche, Bild-Analyse',
                style: TextStyle(color: MFColors.textMuted, fontSize: 12)),
            onChanged: notifier.setAiEnabled,
          ),
          const Divider(color: MFColors.border),

          // ── Profile ──────────────────────────────────────────────────────
          _header('PROFILE'),
          if (state.profiles.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Noch keine Profile. Lege eines an oder nutze „Free-Mix".',
                style: TextStyle(color: MFColors.textMuted, fontSize: 12),
              ),
            ),
          ...state.profiles.map((p) => _ProfileTile(profile: p)),
          const SizedBox(height: 8),
          Row(children: [
            _AddProfileButton(),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => _quickSetup(context, ref),
              icon: const Icon(Icons.auto_awesome, size: 16, color: MFColors.teal),
              label: const Text('Free-Mix', style: TextStyle(color: MFColors.teal)),
            ),
          ]),

          const SizedBox(height: 16),
          // ── Vorgänge → Ketten ────────────────────────────────────────────
          _header('VORGÄNGE (FALLBACK-KETTEN)'),
          for (final task in LlmTask.values)
            _TaskChainRow(task: task),

          const SizedBox(height: 16),
          _header('FALLBACK'),
          _CooldownSetting(),

          const SizedBox(height: 16),
          _header('DIAGNOSE'),
          _DebugToggle(),
        ],
      ),
    );
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t,
            style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: MFColors.textMuted)),
      );

  Future<void> _quickSetup(BuildContext context, WidgetRef ref) async {
    final n = ref.read(llmProfilesProvider.notifier);
    final or = await n.addTemplate(ProviderKind.openrouter);
    final gq = await n.addTemplate(ProviderKind.groq);
    // Kette für alle Text-Vorgänge: OpenRouter (frei) → Groq (frei).
    for (final t in [
      LlmTask.enrichment,
      LlmTask.structuredNote,
      LlmTask.researchedNote
    ]) {
      await n.setChain(t, [or.id, gq.id]);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Free-Mix angelegt — bitte API-Keys in den Profilen eintragen.'),
      ));
    }
  }
}

// ── Profil-Kachel ─────────────────────────────────────────────────────────────

class _ProfileTile extends ConsumerWidget {
  final LlmProfile profile;
  const _ProfileTile({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(llmProfilesProvider);
    final notifier = ref.read(llmProfilesProvider.notifier);
    final isDefault = state.defaultProfileId == profile.id;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MFColors.border),
      ),
      child: ListTile(
        title: Row(children: [
          Flexible(
            child: Text(profile.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: MFColors.textPrimary, fontWeight: FontWeight.w600)),
          ),
          if (isDefault)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.star_rounded, size: 14, color: MFColors.teal),
            ),
        ]),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${profile.kind.label} · ${profile.model}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: MFColors.textMuted, fontSize: 11)),
            const SizedBox(height: 4),
            Wrap(spacing: 4, children: [
              if (profile.isLocal) _chip('Lokal', const Color(0xFF22C55E)),
              _chip(profile.tier == LlmTier.paid ? 'Bezahlt' : 'Frei',
                  profile.tier == LlmTier.paid
                      ? const Color(0xFFF59E0B)
                      : const Color(0xFF38BDF8)),
              if (profile.supportsVision)
                _chip('Vision', const Color(0xFF8B5CF6)),
              if (profile.needsApiKey && !profile.hasApiKey)
                _chip('Kein Key', Colors.redAccent),
            ]),
          ],
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: MFColors.textMuted),
          color: MFColors.surface,
          onSelected: (v) async {
            switch (v) {
              case 'edit':
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ProfileEditorScreen(profileId: profile.id)));
                break;
              case 'default':
                await notifier.setDefault(profile.id);
                break;
              case 'delete':
                await notifier.deleteProfile(profile.id);
                break;
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
            if (!isDefault)
              const PopupMenuItem(value: 'default', child: Text('Als Standard')),
            const PopupMenuItem(value: 'delete', child: Text('Löschen')),
          ],
        ),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ProfileEditorScreen(profileId: profile.id))),
      ),
    );
  }

  Widget _chip(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(t, style: TextStyle(fontSize: 9, color: c)),
      );
}

class _AddProfileButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<ProviderKind>(
      onSelected: (kind) async {
        final p = await ref.read(llmProfilesProvider.notifier).addTemplate(kind);
        if (context.mounted) {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ProfileEditorScreen(profileId: p.id)));
        }
      },
      color: MFColors.surface,
      itemBuilder: (_) => ProviderKind.values
          .map((k) => PopupMenuItem(value: k, child: Text(k.label)))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: MFColors.tealBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF0F766E)),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.add_rounded, size: 16, color: MFColors.teal),
          SizedBox(width: 4),
          Text('Profil', style: TextStyle(color: MFColors.teal, fontSize: 13)),
        ]),
      ),
    );
  }
}

// ── Vorgang → Kette ───────────────────────────────────────────────────────────

class _TaskChainRow extends ConsumerWidget {
  final LlmTask task;
  const _TaskChainRow({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(llmProfilesProvider);
    final ids = state.taskAssignment.chainFor(task);
    final names = ids
        .map((id) => state.profiles
            .where((p) => p.id == id)
            .map((p) => p.name)
            .firstOrNull)
        .whereType<String>()
        .toList();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(task.label,
          style: const TextStyle(color: MFColors.textPrimary, fontSize: 13)),
      subtitle: Text(
        names.isEmpty ? 'Standard-Profil' : names.join('  →  '),
        style: const TextStyle(color: MFColors.textMuted, fontSize: 11),
      ),
      trailing: const Icon(Icons.tune_rounded, size: 18, color: MFColors.teal),
      onTap: () => _editChain(context, ref),
    );
  }

  Future<void> _editChain(BuildContext context, WidgetRef ref) async {
    final state = ref.read(llmProfilesProvider);
    final selected = [...state.taskAssignment.chainFor(task)];
    await showModalBottomSheet(
      context: context,
      backgroundColor: MFColors.surface,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(builder: (ctx, setSheet) {
        final available =
            state.profiles.where((p) => !selected.contains(p.id)).toList();
        // Vision-Hinweis, falls Cloud-Profil für Vision/sensibel.
        final hasCloud = selected
            .map((id) => state.profiles.where((p) => p.id == id).firstOrNull)
            .whereType<LlmProfile>()
            .any((p) => !p.isLocal);
        return Padding(
          padding: EdgeInsets.only(
              left: 16, right: 16, top: 16,
              bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Kette: ${task.label}',
                style: const TextStyle(
                    color: MFColors.textPrimary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (selected.isEmpty)
              const Text('Keine — nutzt Standard-Profil.',
                  style: TextStyle(color: MFColors.textMuted, fontSize: 12)),
            // Gewählte Kette (mit Reihenfolge)
            ...selected.asMap().entries.map((e) {
              final p =
                  state.profiles.where((x) => x.id == e.value).firstOrNull;
              if (p == null) return const SizedBox.shrink();
              return ListTile(
                dense: true,
                leading: Text('${e.key + 1}',
                    style: const TextStyle(color: MFColors.teal)),
                title: Text(p.name,
                    style: const TextStyle(color: MFColors.textPrimary)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (e.key > 0)
                    IconButton(
                      icon: const Icon(Icons.arrow_upward, size: 16),
                      color: MFColors.textMuted,
                      onPressed: () => setSheet(() {
                        final v = selected.removeAt(e.key);
                        selected.insert(e.key - 1, v);
                      }),
                    ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline, size: 16),
                    color: Colors.redAccent,
                    onPressed: () => setSheet(() => selected.removeAt(e.key)),
                  ),
                ]),
              );
            }),
            if (available.isNotEmpty) ...[
              const Divider(color: MFColors.border),
              const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Hinzufügen:',
                      style: TextStyle(color: MFColors.textMuted, fontSize: 11))),
              Wrap(
                spacing: 6,
                children: available
                    .map((p) => ActionChip(
                          label: Text(p.name,
                              style: const TextStyle(fontSize: 12)),
                          backgroundColor: MFColors.surfaceAlt,
                          onPressed: () => setSheet(() => selected.add(p.id)),
                        ))
                    .toList(),
              ),
            ],
            if (task == LlmTask.vision && hasCloud)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '⚠️ Cloud-Profil: Bilder/Inhalte verlassen das Gerät.',
                  style: TextStyle(color: Color(0xFFF59E0B), fontSize: 11),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: MFColors.teal),
              onPressed: () async {
                await ref
                    .read(llmProfilesProvider.notifier)
                    .setChain(task, selected);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Speichern'),
            ),
          ]),
        );
      }),
    );
  }
}

class _DebugToggle extends StatefulWidget {
  @override
  State<_DebugToggle> createState() => _DebugToggleState();
}

class _DebugToggleState extends State<_DebugToggle> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    AiService.isDebug().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: _on,
      activeColor: MFColors.teal,
      contentPadding: EdgeInsets.zero,
      title: const Text('Diagnose-Popup',
          style: TextStyle(color: MFColors.textPrimary, fontSize: 13)),
      subtitle: const Text(
          'Zeigt nach „KI aus Bild": erkannter Typ/Titel/URL, welche Suche/API lief, welches Modell genutzt wurde',
          style: TextStyle(color: MFColors.textMuted, fontSize: 11)),
      onChanged: (v) async {
        setState(() => _on = v);
        await AiService.setDebug(v);
      },
    );
  }
}

class _CooldownSetting extends StatefulWidget {
  @override
  State<_CooldownSetting> createState() => _CooldownSettingState();
}

class _CooldownSettingState extends State<_CooldownSetting> {
  int _minutes = 10;

  @override
  void initState() {
    super.initState();
    AiService.cooldownMinutes().then((m) {
      if (mounted) setState(() => _minutes = m);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Cooldown bei Limit',
          style: TextStyle(color: MFColors.textPrimary, fontSize: 13)),
      subtitle: const Text(
          'Wie lange ein limitiertes (freies) Profil übersprungen wird, wenn kein Reset-Header kommt',
          style: TextStyle(color: MFColors.textMuted, fontSize: 11)),
      trailing: DropdownButton<int>(
        value: _minutes,
        dropdownColor: MFColors.surface,
        style: const TextStyle(color: MFColors.textPrimary),
        items: const [2, 5, 10, 30, 60, 240, 1440]
            .map((m) => DropdownMenuItem(
                value: m,
                child: Text(m >= 60 ? '${m ~/ 60} h' : '$m min')))
            .toList(),
        onChanged: (v) async {
          if (v == null) return;
          setState(() => _minutes = v);
          await AiService.setCooldownMinutes(v);
        },
      ),
    );
  }
}

// ── Profil-Editor ─────────────────────────────────────────────────────────────

class ProfileEditorScreen extends ConsumerStatefulWidget {
  final String profileId;
  const ProfileEditorScreen({super.key, required this.profileId});

  @override
  ConsumerState<ProfileEditorScreen> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends ConsumerState<ProfileEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  final _key = TextEditingController();
  double _temp = 0.3;
  int _maxTokens = 800;
  LlmTier _tier = LlmTier.free;
  bool _vision = false;

  List<Map<String, dynamic>> _models = [];
  bool _loadingModels = false;
  bool _freeOnly = false;
  bool _visionOnly = false;
  String _search = '';
  String _testState = 'idle';
  String _testMsg = '';

  LlmProfile get _p => ref
      .read(llmProfilesProvider)
      .profiles
      .firstWhere((p) => p.id == widget.profileId);

  @override
  void initState() {
    super.initState();
    final p = _p;
    _name = TextEditingController(text: p.name);
    _baseUrl = TextEditingController(text: p.baseUrl);
    _model = TextEditingController(text: p.model);
    _temp = p.temperature;
    _maxTokens = p.maxTokens;
    _tier = p.tier;
    _vision = p.supportsVision;
    ref.read(llmProfilesProvider.notifier).loadApiKey(p.id).then((k) {
      if (mounted && k != null) _key.text = k;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final n = ref.read(llmProfilesProvider.notifier);
    await n.updateProfile(_p.copyWith(
      name: _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      temperature: _temp,
      maxTokens: _maxTokens,
      tier: _tier,
      supportsVision: _vision,
    ));
    await n.saveApiKey(widget.profileId, _key.text.trim());
    if (mounted) Navigator.pop(context);
  }

  Future<void> _loadModels() async {
    setState(() => _loadingModels = true);
    try {
      final models = await OpenRouterService.getModels(_key.text.trim(),
          modelsUrl: _p.copyWith(baseUrl: _baseUrl.text.trim()).modelsUrl);
      if (mounted) setState(() => _models = models);
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _test() async {
    setState(() {
      _testState = 'loading';
      _testMsg = '';
    });
    try {
      final svc = OpenRouterService(
        apiKey: _key.text.trim(),
        model: _model.text.trim(),
        chatUrl: _p.copyWith(baseUrl: _baseUrl.text.trim()).chatUrl,
      );
      await svc.testConnection();
      if (mounted) setState(() => _testState = 'ok');
    } catch (e) {
      if (mounted) {
        setState(() {
          _testState = 'error';
          _testMsg = '$e';
        });
      }
    }
  }

  List<Map<String, dynamic>> get _filtered => _models.where((m) {
        if (_freeOnly && !modelIsFree(m)) return false;
        if (_visionOnly && !modelSupportsVision(m)) return false;
        if (_search.isNotEmpty) {
          final s = '${m['id']} ${m['name']}'.toLowerCase();
          if (!s.contains(_search.toLowerCase())) return false;
        }
        return true;
      }).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        iconTheme: const IconThemeData(color: MFColors.textSecondary),
        title: const Text('Profil bearbeiten',
            style: TextStyle(color: MFColors.textPrimary, fontSize: 17)),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Speichern', style: TextStyle(color: MFColors.teal)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field('Name', _name),
          _field('Basis-URL (OpenAI-kompatibel)', _baseUrl),
          _field('API-Key', _key, obscure: true),
          Row(children: [
            Expanded(child: _field('Modell', _model)),
            const SizedBox(width: 8),
            _SmallButton(
                label: _loadingModels ? '…' : 'Modelle',
                onTap: _loadingModels ? null : _loadModels),
          ]),
          if (_models.isNotEmpty) _modelPicker(),
          const SizedBox(height: 12),
          Row(children: [
            const Text('Temperatur', style: TextStyle(color: MFColors.textSecondary, fontSize: 12)),
            Expanded(
              child: Slider(
                value: _temp,
                min: 0,
                max: 1.5,
                divisions: 15,
                activeColor: MFColors.teal,
                label: _temp.toStringAsFixed(1),
                onChanged: (v) => setState(() => _temp = v),
              ),
            ),
            Text(_temp.toStringAsFixed(1),
                style: const TextStyle(color: MFColors.textMuted)),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _tier == LlmTier.paid,
            activeColor: MFColors.teal,
            title: const Text('Bezahltes Modell (mit Guthaben)',
                style: TextStyle(color: MFColors.textPrimary, fontSize: 13)),
            subtitle: const Text('Wird im Fallback nicht wegen Limits übersprungen',
                style: TextStyle(color: MFColors.textMuted, fontSize: 11)),
            onChanged: (v) => setState(() => _tier = v ? LlmTier.paid : LlmTier.free),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _vision,
            activeColor: MFColors.teal,
            title: const Text('Vision-fähig (Bilder)',
                style: TextStyle(color: MFColors.textPrimary, fontSize: 13)),
            onChanged: (v) => setState(() => _vision = v),
          ),
          const SizedBox(height: 8),
          Row(children: [
            _SmallButton(
                label: switch (_testState) {
                  'loading' => 'Teste…',
                  'ok' => 'OK ✓',
                  'error' => 'Fehler',
                  _ => 'Verbindung testen',
                },
                onTap: _testState == 'loading' ? null : _test),
            const SizedBox(width: 10),
            if (_testState == 'error')
              Expanded(
                child: Text(_testMsg,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
              ),
          ]),
        ],
      ),
    );
  }

  Widget _modelPicker() {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: MFColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: MFColors.border),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                style: const TextStyle(fontSize: 12, color: MFColors.textPrimary),
                decoration: const InputDecoration(
                    isDense: true, hintText: 'Filter…',
                    hintStyle: TextStyle(color: MFColors.textMuted)),
              ),
            ),
            _filterChip('Frei', _freeOnly, (v) => setState(() => _freeOnly = v)),
            _filterChip('Vision', _visionOnly, (v) => setState(() => _visionOnly = v)),
          ]),
        ),
        SizedBox(
          height: 180,
          child: ListView(
            children: _filtered.take(80).map((m) {
              final id = '${m['id']}';
              return ListTile(
                dense: true,
                title: Text(id,
                    style: const TextStyle(color: MFColors.textPrimary, fontSize: 12)),
                trailing: Wrap(spacing: 4, children: [
                  if (modelIsFree(m))
                    const Icon(Icons.money_off, size: 14, color: Color(0xFF38BDF8)),
                  if (modelSupportsVision(m))
                    const Icon(Icons.visibility, size: 14, color: Color(0xFF8B5CF6)),
                ]),
                onTap: () => setState(() {
                  _model.text = id;
                  _vision = modelSupportsVision(m);
                  if (!modelIsFree(m)) _tier = LlmTier.paid;
                }),
              );
            }).toList(),
          ),
        ),
      ]),
    );
  }

  Widget _filterChip(String t, bool v, ValueChanged<bool> onCh) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: FilterChip(
          label: Text(t, style: const TextStyle(fontSize: 11)),
          selected: v,
          showCheckmark: false,
          selectedColor: MFColors.tealBg,
          backgroundColor: MFColors.surfaceAlt,
          onSelected: onCh,
        ),
      );

  Widget _field(String label, TextEditingController c, {bool obscure = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          obscureText: obscure,
          style: const TextStyle(color: MFColors.textPrimary, fontSize: 13),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(color: MFColors.textMuted, fontSize: 12),
            filled: true,
            fillColor: MFColors.surface,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: MFColors.border)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: MFColors.border)),
          ),
        ),
      );
}

class _SmallButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _SmallButton({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: MFColors.tealBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF0F766E)),
          ),
          child: Text(label, style: const TextStyle(color: MFColors.teal, fontSize: 12)),
        ),
      );
}
