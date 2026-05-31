import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/di.dart';
import '../../data/db/app_database.dart';
import '../../data/repositories/container_repository.dart';

final containerRepositoryProvider = Provider<ContainerRepository>((ref) {
  return ContainerRepository(
    containerDao: ref.watch(containerDaoProvider),
    entryDao: ref.watch(entryDaoProvider),
  );
});

// Alle Container flach
final allContainersProvider = StreamProvider<List<Container>>((ref) {
  return ref.watch(containerRepositoryProvider).watchAll();
});

// Gefiltert nach Kind + als Baum
final projectsProvider =
    StreamProvider<List<ContainerWithChildren>>((ref) {
  return ref.watch(containerRepositoryProvider).watchTree('project');
});

final areasProvider =
    StreamProvider<List<ContainerWithChildren>>((ref) {
  return ref.watch(containerRepositoryProvider).watchTree('area');
});

final hubsProvider =
    StreamProvider<List<ContainerWithChildren>>((ref) {
  return ref.watch(containerRepositoryProvider).watchTree('hub');
});
