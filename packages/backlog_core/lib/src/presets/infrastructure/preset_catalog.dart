import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../infrastructure/backlog_layout.dart';
import '../../shared/errors.dart';
import '../domain/init_preset.dart';
import 'built_in_presets.dart';

/// The presets `backlog init` can start from: the built-in ones and the
/// user's, folders in [userDir] (`~/.config/kanban-ai/presets/<name>/`),
/// which replace a built-in one of the same name.
///
/// A preset folder holds `backlog.yaml` (required), `views/*.yaml` (else
/// the default views), `AGENTS.md` (the guide for the repository, optional)
/// and `preset.yaml` (optional, `description: …`).
final class PresetCatalog {
  const PresetCatalog({this.userDir});

  /// Where the user's presets live, from the environment like the project
  /// registry: `$XDG_CONFIG_HOME/kanban-ai/presets`, else
  /// `$HOME/.config/kanban-ai/presets`; null without either.
  static String? userDirFor(Map<String, String> environment) {
    String? given(String name) {
      final value = environment[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final config = given('XDG_CONFIG_HOME') ?? (given('HOME') == null ? null : p.join(given('HOME')!, '.config'));
    return config == null ? null : p.normalize(p.absolute(config, 'kanban-ai', 'presets'));
  }

  final String? userDir;

  /// Every preset by name: built-in ones first, then the user's (a user
  /// preset named like a built-in one takes its place).
  Future<List<InitPreset>> list() async {
    final presets = {for (final preset in builtInPresets) preset.name: preset};
    final dir = userDir == null ? null : Directory(userDir!);
    if (dir != null && await dir.exists()) {
      final folders = await dir.list().where((entity) => entity is Directory).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final folder in folders) {
        if (!await File(p.join(folder.path, BacklogLayout.configFileName)).exists()) continue;
        final name = p.basename(folder.path);
        presets[name] = await fromFolder(folder.path, name: name);
      }
    }
    return presets.values.toList();
  }

  /// The preset [reference] names: a folder when it contains a path
  /// separator or starts with `.` or `~` (relative to [cwd]), else a name of
  /// [list].
  Future<InitPreset> resolve(String reference, {required String cwd, String? home}) async {
    if (reference.contains('/') || reference.contains(p.separator) || reference.startsWith('.') || reference == '~') {
      var path = reference;
      if (home != null && (path == '~' || path.startsWith('~/'))) path = p.join(home, path.substring(1));
      return fromFolder(p.normalize(p.join(cwd, path)));
    }
    final presets = await list();
    for (final preset in presets) {
      if (preset.name == reference) return preset;
    }
    throw NotFoundException(
      'No preset "$reference"; there are ${presets.map((preset) => preset.name).join(', ')} '
      '(`backlog init --list-presets`), or give a folder.',
    );
  }

  /// A preset read from [folder] (see the class documentation).
  static Future<InitPreset> fromFolder(String folder, {String? name}) async {
    final config = File(p.join(folder, BacklogLayout.configFileName));
    if (!await config.exists()) {
      throw NotFoundException('No preset in $folder: it needs a ${BacklogLayout.configFileName}.');
    }
    var description = '';
    final meta = File(p.join(folder, 'preset.yaml'));
    if (await meta.exists()) {
      final Object? yaml;
      try {
        yaml = loadYaml(await meta.readAsString());
      } on YamlException catch (error) {
        throw ConfigurationException('${meta.path}: ${error.message}');
      }
      if (yaml is Map && yaml['description'] is String) description = (yaml['description'] as String).trim();
    }
    final guide = File(p.join(folder, 'AGENTS.md'));
    return InitPreset(
      name: name ?? p.basename(folder),
      description: description,
      config: await config.readAsString(),
      views: await _views(p.join(folder, 'views')) ?? defaultPresetViews,
      agentsGuide: await guide.exists() ? await guide.readAsString() : null,
      source: folder,
    );
  }

  /// The configuration and views of the backlog at [root] (`--from`), not
  /// its items; no placeholders are filled in them.
  static Future<InitPreset> fromBacklog(String root) async {
    final layout = BacklogLayout(root);
    final config = File(layout.configFile);
    if (!await config.exists()) throw NotFoundException('No ${BacklogLayout.configFileName} in ${layout.root}.');
    return InitPreset(
      name: p.basename(layout.root),
      description: 'The configuration and views of ${layout.root}',
      config: await config.readAsString(),
      views: await _views(layout.viewsDir) ?? const {},
      source: layout.root,
    );
  }

  static Future<Map<String, String>?> _views(String folder) async {
    final dir = Directory(folder);
    if (!await dir.exists()) return null;
    final files = await dir.list().where((entity) => entity is File && entity.path.endsWith('.yaml')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return {for (final file in files) p.basenameWithoutExtension(file.path): await (file as File).readAsString()};
  }
}

/// The views of a preset folder without `views/`.
Map<String, String> get defaultPresetViews => builtInPresets.first.views;
