import '../../shared/errors.dart';
import '../domain/project_registry.dart';

/// Use cases of the project registry: list, register and unregister backlogs.
///
/// Whether a folder really holds a backlog is checked by the caller, which
/// can open it.
final class ProjectService {
  ProjectService(this._store);

  final ProjectRegistryStore _store;

  String get location => _store.location;

  Future<ProjectRegistry> registry() => _store.load();

  /// Registers the backlog at [path] (absolute). Without [id], the id is
  /// derived from the folder and made unique with a numeric suffix.
  Future<ProjectEntry> add(String path, {String? id, String? name}) async {
    final registry = await _store.load();
    final entry = ProjectEntry(id: id ?? registry.uniqueIdFor(path), path: path, name: name);
    registry.add(entry); // validates the id and refuses duplicates
    await _store.append(entry);
    return entry;
  }

  /// Registers the backlog at [path] unless it is registered already;
  /// returns its entry and whether it was added.
  Future<(ProjectEntry, bool)> ensure(String path, {String? name}) async {
    if ((await _store.load()).atPath(path) case final existing?) return (existing, false);
    return (await add(path, name: name), true);
  }

  /// Pins project [id] (clients offer pinned projects first) or unpins it;
  /// returns its updated entry. Throws [NotFoundException] for an unknown id.
  Future<ProjectEntry> setPinned(String id, bool pinned) async {
    final entry = (await _store.load())[id];
    if (entry == null) throw NotFoundException('No project "$id" in the registry.');
    if (entry.pinned != pinned) await _store.setPinned(id, pinned);
    return ProjectEntry(id: entry.id, path: entry.path, name: entry.name, pinned: pinned);
  }

  /// Unregisters project [id]; the backlog itself stays untouched.
  Future<ProjectEntry> remove(String id) async {
    final registry = await _store.load();
    final entry = registry[id];
    registry.remove(id); // throws NotFoundException for an unknown id
    await _store.remove(id);
    return entry!;
  }
}
