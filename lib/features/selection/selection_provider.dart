import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Auswahlmodus aktiv? (app-weit, geteilt von Feed und Aufgaben-Tab)
final selectionModeProvider = StateProvider<bool>((ref) => false);

/// IDs der aktuell ausgewählten Einträge/Aufgaben.
final selectedIdsProvider = StateProvider<Set<String>>((ref) => {});

/// Hilfs-Notifier-Funktionen rund um die Auswahl.
extension SelectionActions on WidgetRef {
  void toggleSelected(String id) {
    final cur = Set<String>.from(read(selectedIdsProvider));
    if (cur.contains(id)) {
      cur.remove(id);
    } else {
      cur.add(id);
    }
    read(selectedIdsProvider.notifier).state = cur;
    // Auswahlmodus automatisch beenden, wenn nichts mehr ausgewählt ist
    if (cur.isEmpty) {
      read(selectionModeProvider.notifier).state = false;
    }
  }

  void enterSelection(String id) {
    read(selectionModeProvider.notifier).state = true;
    read(selectedIdsProvider.notifier).state = {id};
  }

  void clearSelection() {
    read(selectedIdsProvider.notifier).state = {};
    read(selectionModeProvider.notifier).state = false;
  }
}
