import 'package:path/path.dart' as p;

import '../../shared/errors.dart';
import '../../shared/slug.dart';

/// One backlog in the project registry.
final class ProjectEntry {
  /// [path] must be absolute; ids are checked by [ProjectRegistry].
  const ProjectEntry({required this.id, required this.path, this.name});

  /// An entry whose id is derived from [path] (see [ProjectRegistry.deriveId]).
  factory ProjectEntry.at(String path, {String? id, String? name}) =>
      ProjectEntry(id: id ?? ProjectRegistry.deriveId(path), path: path, name: name);

  /// Stable slug used in URLs (`/api/p/<id>/…`).
  final String id;

  /// Absolute path of the backlog folder (the one holding `backlog.yaml`).
  final String path;

  /// Display name as written in the registry; null when not given.
  final String? name;

  /// [name], or the project folder's name.
  String get displayName => name ?? ProjectRegistry.projectFolderName(path);

  @override
  bool operator ==(Object other) => other is ProjectEntry && other.id == id && other.path == path && other.name == name;

  @override
  int get hashCode => Object.hash(id, path, name);

  @override
  String toString() => '$id ($path)';
}

/// The ordered list of backlogs one server hosts; the first one is the
/// default project.
final class ProjectRegistry {
  /// Throws [ConfigurationException] on an invalid or repeated id.
  ProjectRegistry(Iterable<ProjectEntry> entries) : entries = List.unmodifiable(entries) {
    final seen = <String>{};
    for (final entry in this.entries) {
      final problem = idProblem(entry.id);
      if (problem != null) throw ConfigurationException('Project "${entry.id}": $problem');
      if (!seen.add(entry.id)) {
        throw ConfigurationException('Project id "${entry.id}" is used twice; give one of them another `id:`.');
      }
    }
  }

  static final empty = ProjectRegistry(const []);

  static final _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]*$');

  final List<ProjectEntry> entries;

  bool get isEmpty => entries.isEmpty;

  /// The project served on the unprefixed paths.
  ProjectEntry? get defaultProject => entries.isEmpty ? null : entries.first;

  ProjectEntry? operator [](String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  ProjectEntry? atPath(String path) {
    final normalized = p.normalize(path);
    for (final entry in entries) {
      if (p.normalize(entry.path) == normalized) return entry;
    }
    return null;
  }

  /// Why [id] cannot be a project id, or null when it can.
  static String? idProblem(String id) => _idPattern.hasMatch(id)
      ? null
      : 'an id is lower-case letters, digits, "-" and "_", starting with a letter or digit';

  /// The folder that names the project: the backlog folder itself, or its
  /// parent when it is called `backlog` (`~/p/hobbyo/backlog` → `hobbyo`).
  static String projectFolderName(String path) {
    final normalized = p.normalize(path);
    final base = p.basename(normalized);
    if (base != 'backlog') return base;
    final parent = p.basename(p.dirname(normalized));
    return parent.isEmpty || parent == p.separator ? base : parent;
  }

  /// A slug of [projectFolderName].
  static String deriveId(String path) {
    final slug = slugify(projectFolderName(path));
    return slug.isEmpty ? 'project' : slug;
  }

  /// [deriveId], suffixed with `-2`, `-3`, … until no entry uses it.
  String uniqueIdFor(String path) {
    final base = deriveId(path);
    var candidate = base;
    for (var n = 2; this[candidate] != null; n++) {
      candidate = '$base-$n';
    }
    return candidate;
  }

  /// This registry with [entry] appended. Throws [InvalidInputException]
  /// when its id or folder is already registered.
  ProjectRegistry add(ProjectEntry entry) {
    final problem = idProblem(entry.id);
    if (problem != null) throw InvalidInputException('Project id "${entry.id}": $problem.');
    if (this[entry.id] != null) throw InvalidInputException('Project id "${entry.id}" is already registered.');
    if (atPath(entry.path) case final existing?) {
      throw InvalidInputException('${entry.path} is already registered as "${existing.id}".');
    }
    return ProjectRegistry([...entries, entry]);
  }

  /// This registry without project [id]. Throws [NotFoundException].
  ProjectRegistry remove(String id) {
    if (this[id] == null) throw NotFoundException('No project "$id" in the registry.');
    return ProjectRegistry([
      for (final entry in entries)
        if (entry.id != id) entry,
    ]);
  }
}

/// Where the registry is kept (a port; the YAML file adapter is in
/// infrastructure).
abstract interface class ProjectRegistryStore {
  /// Where the registry lives, for messages.
  String get location;

  /// The registry; empty when it does not exist yet. Throws
  /// [ConfigurationException] when it is malformed.
  Future<ProjectRegistry> load();

  /// Appends [entry], keeping everything else (comments included).
  Future<void> append(ProjectEntry entry);

  /// Removes the entry of project [id], keeping everything else.
  Future<void> remove(String id);
}
