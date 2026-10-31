import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../infrastructure/backlog_layout.dart';
import '../../shared/errors.dart';
import '../domain/project_registry.dart';

/// The registry file: `$BACKLOG_PROJECTS`, else
/// `$XDG_CONFIG_HOME/kanban-ai/projects.yaml`, else
/// `~/.config/kanban-ai/projects.yaml`; null without any of these variables.
String? projectRegistryFile(Map<String, String> environment) {
  String? given(String name) {
    final value = environment[name]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  if (given('BACKLOG_PROJECTS') case final file?) return p.normalize(p.absolute(file));
  final config =
      given('XDG_CONFIG_HOME') ??
      switch (given('HOME')) {
        final home? => p.join(home, '.config'),
        null => null,
      };
  return config == null ? null : p.normalize(p.absolute(config, 'kanban-ai', 'projects.yaml'));
}

/// Parses the registry; `path`s are absolute, `~/…` (under [home]) or
/// relative to [baseDir], the folder of the file.
ProjectRegistry parseProjectRegistryYaml(String source, {required String baseDir, String? home, String? origin}) {
  final where = origin == null ? '' : '$origin: ';
  final Object? yaml;
  try {
    yaml = loadYaml(source);
  } on YamlException catch (e) {
    throw ConfigurationException('$where${e.message}');
  }
  if (yaml == null) return ProjectRegistry.empty;
  if (yaml is! YamlMap) throw ConfigurationException('${where}expected a mapping with a `projects:` list.');
  final list = yaml['projects'];
  if (list == null) return ProjectRegistry.empty;
  if (list is! YamlList) throw ConfigurationException('$where`projects` must be a list.');
  final entries = <ProjectEntry>[];
  for (final (index, node) in list.indexed) {
    final at = '${where}projects[$index]';
    if (node is! YamlMap) throw ConfigurationException('$at: expected a mapping with `path`.');
    String? text(String key) {
      final value = node[key];
      if (value == null) return null;
      if (value is Map || value is List) throw ConfigurationException('$at: `$key` must be text.');
      final trimmed = '$value'.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final raw = text('path') ?? (throw ConfigurationException('$at: `path` is missing.'));
    final pinned = node['pinned'] ?? false;
    if (pinned is! bool) throw ConfigurationException('$at: `pinned` must be true or false.');
    entries.add(
      ProjectEntry.at(
        resolveRegistryPath(raw, baseDir: baseDir, home: home),
        id: text('id'),
        name: text('name'),
        pinned: pinned,
      ),
    );
  }
  try {
    return ProjectRegistry(entries);
  } on ConfigurationException catch (e) {
    throw ConfigurationException('$where${e.message}');
  }
}

/// [raw] as an absolute, normalized path (see [parseProjectRegistryYaml]).
String resolveRegistryPath(String raw, {required String baseDir, String? home}) {
  if (home != null && (raw == '~' || raw.startsWith('~/'))) {
    return p.normalize(p.join(home, raw.substring(1).replaceFirst(RegExp('^/'), '')));
  }
  return p.normalize(p.join(baseDir, raw));
}

/// The registry in a YAML file (see [projectRegistryFile]). Edits keep the
/// rest of the file, comments included.
final class YamlProjectRegistryStore implements ProjectRegistryStore {
  YamlProjectRegistryStore(String file, {this.home}) : file = p.normalize(p.absolute(file));

  final String file;

  /// Expands `~/` in paths and is used to shorten written paths.
  final String? home;

  static const _header =
      '# Backlogs served by backlog-server (see `backlog projects`); the first one is the default.\n'
      '# path: absolute, ~/… or relative to this file; id and name are optional.\n';

  @override
  String get location => file;

  @override
  Future<ProjectRegistry> load() async {
    final source = await _read();
    return source == null
        ? ProjectRegistry.empty
        : parseProjectRegistryYaml(source, baseDir: p.dirname(file), home: home, origin: file);
  }

  @override
  Future<void> append(ProjectEntry entry) async {
    final source = await _read() ?? '';
    final node = {
      'id': entry.id,
      if (entry.name != null) 'name': entry.name,
      'path': _written(entry.path),
      if (entry.pinned) 'pinned': true,
    };
    final String updated;
    if (loadYaml(source) case {'projects': final YamlList list} when list.isNotEmpty) {
      updated = (YamlEditor(source)..appendToList(['projects'], node)).toString();
    } else if (loadYaml(source) is YamlMap) {
      updated = (YamlEditor(source)..update(['projects'], [node])).toString();
    } else {
      final prefix = source.trim().isEmpty ? _header : source.trimRight();
      final block =
          (YamlEditor('')..update([], {
                'projects': [node],
              }))
              .toString();
      updated = '$prefix${prefix.endsWith('\n') ? '' : '\n'}$block\n';
    }
    await writeAtomically(File(file), updated);
  }

  @override
  Future<void> remove(String id) async {
    final source = await _read();
    final registry = source == null ? ProjectRegistry.empty : await load();
    final index = registry.entries.indexWhere((entry) => entry.id == id);
    if (index < 0) throw NotFoundException('No project "$id" in $file.');
    await writeAtomically(File(file), (YamlEditor(source!)..remove(['projects', index])).toString());
  }

  Future<String?> _read() async {
    final handle = File(file);
    return await handle.exists() ? handle.readAsString() : null;
  }

  /// `~/…` under [home], else absolute.
  String _written(String path) {
    if (home case final home? when p.isWithin(home, path)) {
      return '~/${p.posix.joinAll(p.split(p.relative(path, from: home)))}';
    }
    return path;
  }
}
