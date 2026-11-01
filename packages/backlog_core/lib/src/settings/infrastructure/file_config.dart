import 'dart:io';

import 'package:path/path.dart' as p;

import '../../infrastructure/backlog_layout.dart';
import '../../projects/infrastructure/yaml_project_registry.dart';
import '../../shared/errors.dart';
import '../../workflow/infrastructure/yaml_workflow.dart';
import '../application/config_editor.dart';
import '../domain/config_file.dart';
import '../domain/server_config.dart';

/// A configuration file on disk, written atomically. File-system failures
/// (no permission, read-only folder) become [UnavailableException]s.
final class FileConfigFile implements ConfigFile {
  FileConfigFile(String path) : location = p.normalize(p.absolute(path));

  @override
  final String location;

  @override
  Future<String?> read() async {
    final file = File(location);
    try {
      return await file.exists() ? await file.readAsString() : null;
    } on FileSystemException catch (e) {
      throw UnavailableException('Cannot read $location: ${_reason(e)}');
    }
  }

  @override
  Future<void> write(String content) async {
    try {
      await writeAtomically(File(location), content);
    } on FileSystemException catch (e) {
      throw UnavailableException('Cannot write $location: ${_reason(e)}');
    }
  }

  static String _reason(FileSystemException e) => switch (e.osError?.message) {
    final String os when os.isNotEmpty => os,
    _ => e.message,
  };
}

/// The editor of the project's `backlog.yaml` in the backlog folder [root];
/// a draft is valid when it parses as a workflow.
ConfigEditor projectConfigEditor(String root) {
  final file = BacklogLayout(root).configFile;
  return ConfigEditor(
    scope: ConfigScope.project,
    file: FileConfigFile(file),
    validate: (source) => parseWorkflowYaml(source, origin: file),
  );
}

/// The editor of the project registry [file] (see `projectRegistryFile`);
/// `~/` in paths expands under [home].
ConfigEditor registryConfigEditor(String file, {String? home}) {
  final location = p.normalize(p.absolute(file));
  return ConfigEditor(
    scope: ConfigScope.global,
    file: FileConfigFile(location),
    validate: (source) => parseProjectRegistryYaml(source, baseDir: p.dirname(location), home: home, origin: location),
  );
}

/// The server settings file: `$BACKLOG_SERVER_CONFIG`, else
/// `$XDG_CONFIG_HOME/kanban-ai/server.yaml`, else
/// `~/.config/kanban-ai/server.yaml`; null without any of these variables.
String? serverConfigFile(Map<String, String> environment) {
  String? given(String name) {
    final value = environment[name]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  if (given('BACKLOG_SERVER_CONFIG') case final file?) return p.normalize(p.absolute(file));
  final config =
      given('XDG_CONFIG_HOME') ??
      switch (given('HOME')) {
        final home? => p.join(home, '.config'),
        null => null,
      };
  return config == null ? null : p.normalize(p.absolute(config, 'kanban-ai', 'server.yaml'));
}

/// Reads the server settings [file]; a missing file is [ServerConfig.empty].
/// Throws [ConfigurationException] for an invalid one and
/// [UnavailableException] for one that cannot be read.
Future<ServerConfig> loadServerConfig(String file, {String? home}) async {
  final location = p.normalize(p.absolute(file));
  final source = await FileConfigFile(location).read();
  if (source == null) return ServerConfig.empty;
  return parseServerConfigYaml(source, baseDir: p.dirname(location), home: home, origin: location);
}

/// The editor of the server settings [file] (see [serverConfigFile]).
ConfigEditor serverConfigEditor(String file, {String? home}) {
  final location = p.normalize(p.absolute(file));
  return ConfigEditor(
    scope: ConfigScope.global,
    file: FileConfigFile(location),
    validate: (source) => parseServerConfigYaml(source, baseDir: p.dirname(location), home: home, origin: location),
  );
}
