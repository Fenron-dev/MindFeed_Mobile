import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart';
import '../db/app_database.dart';
import '../db/daos/container_dao.dart';
import '../db/daos/entry_dao.dart';

const _uuid = Uuid();

class ContainerWithChildren {
  final Container container;
  final List<ContainerWithChildren> children;
  final int entryCount;

  const ContainerWithChildren({
    required this.container,
    required this.children,
    required this.entryCount,
  });
}

class ContainerRepository {
  final ContainerDao containerDao;
  final EntryDao entryDao;

  ContainerRepository({required this.containerDao, required this.entryDao});

  Stream<List<ContainerWithChildren>> watchTree(String kind) {
    return containerDao.watchByKind(kind).asyncMap((flat) async {
      return _buildTree(flat, null);
    });
  }

  Stream<List<Container>> watchAll() => containerDao.watchAll();

  Future<Container> create({
    required String kind,
    required String name,
    String? description,
    String icon = 'folder',
    String color = '#14B8A6',
    String? parentId,
    String? filterTag,
    String? filterStatus,
    String? filterType,
  }) async {
    final id = 'c-${_uuid.v4()}';
    final companion = ContainersCompanion(
      id: Value(id),
      kind: Value(kind),
      name: Value(name),
      description: Value(description),
      icon: Value(icon),
      color: Value(color),
      parentId: Value(parentId),
      filterTag: Value(filterTag),
      filterStatus: Value(filterStatus),
      filterType: Value(filterType),
    );
    await containerDao.upsert(companion);
    return (await (containerDao.watchAll().first))
        .firstWhere((c) => c.id == id);
  }

  Future<void> delete(String id) => containerDao.deleteById(id);

  List<ContainerWithChildren> _buildTree(
      List<Container> all, String? parentId) {
    return all
        .where((c) => c.parentId == parentId)
        .map((c) => ContainerWithChildren(
              container: c,
              children: _buildTree(all, c.id),
              entryCount: 0, // TODO: count via DAO
            ))
        .toList();
  }
}
