import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../infrastructure/backlog_layout.dart';
import '../../shared/errors.dart';
import '../domain/workflow_source.dart';
import 'yaml_workflow.dart';

/// The workflow in `backlog.yaml`. The revision is a hash of the file's
/// content (file times are too coarse to tell quick edits apart); edits go
/// through `yaml_edit` and keep comments, key order and unknown keys.
final class FileWorkflowSource implements WorkflowSource {
  FileWorkflowSource(this._layout);

  final BacklogLayout _layout;

  @override
  String get location => _layout.configFile;

  @override
  Future<WorkflowRevision?> revision() async {
    final bytes = await _read();
    return bytes == null ? null : _revision(bytes);
  }

  @override
  Future<LoadedWorkflow> load() async {
    final bytes = await _read() ?? (throw _missing());
    return LoadedWorkflow(parseWorkflowYaml(utf8.decode(bytes), origin: location), _revision(bytes));
  }

  @override
  Future<WorkflowRevision> edit(List<WorkflowEdit> edits, {WorkflowRevision? expected}) async {
    final bytes = await _read() ?? (throw _missing());
    if (expected != null && _revision(bytes) != expected) {
      throw UnavailableException('$location changed since it was read; load it again and retry.');
    }
    final source = utf8.decode(bytes);
    var updated = source;
    for (final edit in edits) {
      updated = applyWorkflowEdit(updated, edit, origin: location);
    }
    if (updated == source) return _revision(bytes);
    parseWorkflowYaml(updated, origin: location); // never write what could not be read back
    await writeAtomically(File(location), updated);
    return _revision(utf8.encode(updated));
  }

  Future<List<int>?> _read() async {
    final file = File(location);
    return await file.exists() ? file.readAsBytes() : null;
  }

  NotFoundException _missing() =>
      NotFoundException('No ${BacklogLayout.configFileName} in ${_layout.root}; run `backlog init` first.');

  /// FNV-1a (64 bit) of [bytes], stable across processes.
  static WorkflowRevision _revision(List<int> bytes) {
    var hash = 0xcbf29ce484222325;
    for (final byte in bytes) {
      hash = (hash ^ byte) * 0x100000001b3;
    }
    return WorkflowRevision(hash.toRadixString(16));
  }
}

/// [source] (a `backlog.yaml`) with [edit] applied, keeping everything else.
/// Throws [InvalidInputException] when the path does not fit the document
/// (an empty path, a list position out of range, a scalar in the way).
String applyWorkflowEdit(String source, WorkflowEdit edit, {String origin = 'backlog.yaml'}) {
  final path = edit.path;
  final value = edit.value;
  if (path.isEmpty) throw const InvalidInputException('An edit of the workflow needs a path.');
  final where = path.join('.');
  String upTo(int end) => path.sublist(0, end).join('.');

  Object nested(List<Object> rest) {
    Object result = value!;
    for (final key in rest.reversed) {
      if (key is! String) throw InvalidInputException('Cannot set $where: there is no list to put item $key in.');
      result = {key: result};
    }
    return result;
  }

  final Object? document;
  try {
    document = loadYaml(source);
  } on YamlException catch (e) {
    throw ConfigurationException('$origin: ${e.message}');
  }
  if (document is! YamlMap) {
    if (document != null) throw ConfigurationException('$origin: expected a mapping at the top level.');
    if (value == null) return source;
    // Empty or only comments: keep them and add the setting below.
    final block = (YamlEditor('')..update([], nested(path))).toString();
    final prefix = source.trimRight();
    return prefix.isEmpty ? '$block\n' : '$prefix\n$block\n';
  }

  final editor = YamlEditor(source);
  Object? node = document;
  for (var i = 0; i < path.length; i++) {
    final key = path[i];
    final rest = path.sublist(i + 1);
    switch (node) {
      case final YamlMap map when key is String:
        if (!map.containsKey(key)) {
          if (value != null) editor.update(path.sublist(0, i + 1), nested(rest));
          return editor.toString();
        }
        node = map[key];
      case final YamlList list when key is int:
        if (key == list.length && value != null) {
          editor.appendToList(path.sublist(0, i), nested(rest));
          return editor.toString();
        }
        if (key < 0 || key >= list.length) {
          if (value == null) return source;
          throw InvalidInputException('Cannot set $where: ${upTo(i)} has ${list.length} items.');
        }
        node = list[key];
      case null:
        // An empty value such as `appearance:` becomes the mapping that is needed.
        if (value != null) editor.update(path.sublist(0, i), nested(path.sublist(i)));
        return editor.toString();
      default:
        if (value == null) return source;
        throw InvalidInputException('Cannot set $where: ${upTo(i)} is not a ${key is int ? 'list' : 'mapping'}.');
    }
  }
  if (value == null) {
    editor.remove(path);
  } else {
    editor.update(path, value);
  }
  return editor.toString();
}
