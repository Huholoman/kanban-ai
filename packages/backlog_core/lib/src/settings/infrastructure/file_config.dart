import 'dart:io';

import 'package:path/path.dart' as p;

import '../../infrastructure/backlog_layout.dart';
import '../../projects/infrastructure/yaml_project_registry.dart';
import '../../workflow/infrastructure/yaml_workflow.dart';
import '../application/config_editor.dart';
import '../domain/config_file.dart';

/// A configuration file on disk, written atomically.
final class FileConfigFile implements ConfigFile {
  FileConfigFile(String path) : location = p.normalize(p.absolute(path));

  @override
  final String location;

  @override
  Future<String?> read() async {
    final file = File(location);
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<void> write(String content) => writeAtomically(File(location), content);
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
