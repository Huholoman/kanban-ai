import 'package:path/path.dart' as p;

import '../../projects/domain/project_registry.dart';
import '../../shared/errors.dart';
import 'config_draft.dart';

/// One project of a registry draft: the [id] (written or derived), the
/// [name] and [pinned] as written, the path as written ([rawPath]) and
/// resolved ([path]).
final class RegistryEntry {
  const RegistryEntry({
    required this.id,
    required this.rawPath,
    required this.path,
    this.name,
    this.pinned = false,
    this.idWritten = false,
  });

  final String id;
  final String rawPath;
  final String path;
  final String? name;
  final bool pinned;

  /// Whether the id is in the file (else derived from the folder).
  final bool idWritten;

  String get displayName => name ?? ProjectRegistry.projectFolderName(path);
}

/// Typed reads and edits of a project registry [draft] (`projects.yaml`,
/// §1.2): add, remove, reorder (the first is the default), rename, pin.
/// Paths are relative to [baseDir], `~/` under [home]. Reads are lenient;
/// edits check what they can and keep the rest of the file.
final class RegistrySettings {
  RegistrySettings(this.draft, {required this.baseDir, this.home});

  final ConfigDraft draft;
  final String baseDir;
  final String? home;

  static const _key = 'projects';

  List<RegistryEntry> get entries {
    final list = draft.valueAt([_key]);
    if (list is! List) return const [];
    return [
      for (final node in list)
        if (node is Map) _entry(node) else RegistryEntry(id: '?', rawPath: '$node', path: '$node'),
    ];
  }

  RegistryEntry _entry(Map<Object?, Object?> node) {
    final raw = '${node['path'] ?? ''}'.trim();
    final path = raw.isEmpty ? '' : _resolve(raw);
    final id = node['id']?.toString().trim();
    return RegistryEntry(
      id: id == null || id.isEmpty ? ProjectRegistry.deriveId(path) : id,
      idWritten: id != null && id.isNotEmpty,
      rawPath: raw,
      path: path,
      name: node['name']?.toString(),
      pinned: node['pinned'] == true,
    );
  }

  String _resolve(String raw) {
    if (home != null && (raw == '~' || raw.startsWith('~/'))) {
      return p.normalize(p.join(home!, raw.substring(1).replaceFirst(RegExp('^/'), '')));
    }
    return p.normalize(p.join(baseDir, raw));
  }

  /// Adds the backlog folder [path] (absolute, or `~/…`) at the end, with
  /// an id derived from its folder (made unique); returns that id. Throws
  /// [InvalidInputException] when the folder is registered already.
  String add(String path) {
    final raw = path.trim();
    if (raw.isEmpty) throw const InvalidInputException('Give the folder of the backlog.');
    final resolved = _resolve(raw);
    for (final entry in entries) {
      if (p.equals(entry.path, resolved)) {
        throw InvalidInputException('$resolved is registered already as "${entry.id}".');
      }
    }
    var id = ProjectRegistry.deriveId(resolved);
    final ids = {for (final entry in entries) entry.id};
    for (var n = 2; ids.contains(id); n++) {
      id = '${ProjectRegistry.deriveId(resolved)}-$n';
    }
    final node = {'id': id, 'path': _written(resolved)};
    if (draft.valueAt([_key]) is List) {
      draft.insert([_key], entries.length, node);
    } else {
      draft.set([_key], [node]);
    }
    return id;
  }

  /// `~/…` under [home], else absolute.
  String _written(String path) {
    if (home case final home? when p.isWithin(home, path)) {
      return '~/${p.posix.joinAll(p.split(p.relative(path, from: home)))}';
    }
    return path;
  }

  void remove(int index) {
    _check(index);
    draft.remove([_key, index]);
  }

  /// Moves project [index] to position [to]; position 0 is the default
  /// project.
  void move(int index, int to) {
    _check(index);
    if (to < 0 || to >= entries.length) throw const InvalidInputException('It cannot move further.');
    if (to == index) return;
    final value = draft.valueAt([_key, index]);
    draft
      ..remove([_key, index])
      ..insert([_key], to, value);
  }

  /// Sets the id of project [index] (it appears in URLs).
  void setId(int index, String id) {
    final entry = _check(index);
    final value = id.trim();
    if (ProjectRegistry.idProblem(value) case final problem?) throw InvalidInputException('"$value": $problem.');
    if (value == entry.id) return;
    if (entries.any((other) => other.id == value)) throw InvalidInputException('Project id "$value" is taken.');
    draft.set([_key, index, 'id'], value);
  }

  /// Sets the display name of project [index]; empty removes it (the
  /// folder's name shows).
  void setName(int index, String name) {
    _check(index);
    final value = name.trim();
    if (value.isEmpty) {
      draft.remove([_key, index, 'name']);
    } else {
      draft.set([_key, index, 'name'], value);
    }
  }

  /// Pins project [index] or not (not pinned leaves the key out).
  void setPinned(int index, bool pinned) {
    _check(index);
    if (pinned) {
      draft.set([_key, index, 'pinned'], true);
    } else {
      draft.remove([_key, index, 'pinned']);
    }
  }

  RegistryEntry _check(int index) {
    final all = entries;
    if (index < 0 || index >= all.length) throw InvalidInputException('There is no project ${index + 1}.');
    if (draft.valueAt([_key, index]) is! Map) {
      throw InvalidInputException('Project ${index + 1} is not a mapping with a path; fix it with Edit a value.');
    }
    return all[index];
  }
}
