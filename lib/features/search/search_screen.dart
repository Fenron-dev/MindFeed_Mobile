import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants.dart';
import '../../core/di.dart';
import '../../core/theme.dart';
import '../../data/repositories/entry_repository.dart';
import '../../features/feed/feed_provider.dart';
import '../../widgets/entry_card.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  List<EntryWithDetails> _results = [];
  bool _loading = false;
  bool _hasSearched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      _search(''); // Alle Einträge sofort laden
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(q));
  }

  Future<void> _search(String q) async {
    setState(() => _loading = true);
    try {
      final results =
          await ref.read(entryRepositoryProvider).search(q.trim());
      if (mounted) {
        setState(() {
          _results = results;
          _loading = false;
          _hasSearched = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MFColors.bg,
      appBar: AppBar(
        backgroundColor: MFColors.bg,
        titleSpacing: 0,
        title: TextField(
          controller: _ctrl,
          focusNode: _focus,
          onChanged: _onChanged,
          style: const TextStyle(
              fontSize: 15, color: MFColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Einträge durchsuchen…',
            hintStyle: const TextStyle(color: MFColors.textMuted),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            prefixIcon: const Icon(Icons.search,
                color: MFColors.textMuted, size: 20),
            suffixIcon: _ctrl.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close,
                        color: MFColors.textMuted, size: 18),
                    onPressed: () {
                      _ctrl.clear();
                      _onChanged('');
                    },
                  )
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => context.pop(),
            child: const Text('Abbrechen',
                style: TextStyle(color: MFColors.textSecondary)),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // Wenn kein Suchtext: reaktiven Feed-Stream zeigen (immer aktuell)
    if (_ctrl.text.trim().isEmpty) {
      final feedAsync = ref.watch(feedProvider);
      return feedAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: MFColors.teal)),
        error: (e, _) => Center(child: Text('$e')),
        data: (entries) => _buildList(entries),
      );
    }

    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: MFColors.teal));
    }

    if (!_hasSearched) {
      return const Center(
          child: CircularProgressIndicator(color: MFColors.teal));
    }

    if (_results.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.search_off, size: 40, color: MFColors.border),
          const SizedBox(height: 12),
          Text('Keine Ergebnisse für „${_ctrl.text}"',
              style: const TextStyle(
                  fontSize: 14, color: MFColors.textSecondary)),
        ]),
      );
    }

    return _buildList(_results);
  }

  Widget _buildList(List<EntryWithDetails> items) {
    if (items.isEmpty) {
      return const Center(
        child: Text('Noch keine Einträge',
            style: TextStyle(color: MFColors.textMuted)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 40),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) => EntryCard(
        item: items[i],
        onTap: () =>
            ctx.push(AppRoutes.entryDetailPath(items[i].entry.id)),
      ),
    );
  }
}
