import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../shared/errors.dart';
import 'text_diff.dart';

/// A key path into a YAML document: map keys and list indexes, e.g.
/// `['claims', 'lease_minutes']` or `['statuses', 0, 'id']`.
typedef ConfigPath = List<Object>;

/// Pending edits of one YAML configuration file: the text as read and the
/// text with the edits. Edits go through `yaml_edit`, so comments, key
/// order and unknown keys stay as they are.
final class ConfigDraft {
  ConfigDraft(this.original) : _text = original;

  /// The file as it was read ('' for a missing file).
  final String original;

  String _text;

  /// The file with the edits so far.
  String get text => _text;

  bool get changed => _text != original;

  /// The changed lines with some context (see [diffHunks]).
  List<DiffLine> get diff => diffHunks(original, _text);

  /// Drops every edit.
  void reset() => _text = original;

  /// The value at [path] (maps and lists as read), or null when absent.
  Object? valueAt(ConfigPath path) {
    final node = _nodeAt(_editor(), path);
    return node == null ? null : _plain(node);
  }

  /// Sets [path] to [value] (null, bool, num, String, List or Map), creating
  /// the maps on the way; index `length` of a list appends.
  void set(ConfigPath path, Object? value) {
    final editor = _editor();
    if (path.isEmpty || _nodeAt(editor, const []) is! YamlMap) {
      editor.update(const [], _nest(path, value));
      _text = _withNewline(editor.toString());
      return;
    }
    for (var depth = 1; depth <= path.length; depth++) {
      final parent = _nodeAt(editor, path.sublist(0, depth - 1))!;
      final key = path[depth - 1];
      final rest = path.sublist(depth);
      if (parent is YamlList) {
        if (key is! int || key < 0 || key > parent.length) {
          throw InvalidInputException('${formatConfigPath(path.sublist(0, depth))}: no such list entry.');
        }
        if (key == parent.length) {
          editor.appendToList(path.sublist(0, depth - 1), _nest(rest, value));
          break;
        }
      } else if (parent is! YamlMap || !parent.containsKey(key)) {
        editor.update(path.sublist(0, depth), _nest(rest, value));
        break;
      }
      final node = _nodeAt(editor, path.sublist(0, depth));
      if (rest.isEmpty || (node is! YamlMap && node is! YamlList)) {
        editor.update(path.sublist(0, depth), _nest(rest, value));
        break;
      }
    }
    _text = editor.toString();
  }

  /// Removes [path]; false when it was not there.
  bool remove(ConfigPath path) {
    if (path.isEmpty) throw const InvalidInputException('Give a key to remove.');
    final editor = _editor();
    if (_nodeAt(editor, path) == null) return false;
    editor.remove(path);
    _text = editor.toString();
    return true;
  }

  YamlEditor _editor() {
    try {
      return YamlEditor(_text);
    } on YamlException catch (e) {
      throw ConfigurationException('The file is not valid YAML: ${e.message}');
    }
  }

  /// Returned by `parseAt` for an absent path; told apart by identity.
  static final _missing = wrapAsYamlNode(null);

  static YamlNode? _nodeAt(YamlEditor editor, ConfigPath path) {
    try {
      final node = editor.parseAt(path, orElse: () => _missing);
      return identical(node, _missing) ? null : node;
    } on ArgumentError {
      return null; // a path through a scalar
    }
  }

  static Object? _nest(ConfigPath path, Object? value) {
    var nested = value;
    for (final key in path.reversed) {
      if (key is int) throw InvalidInputException('Cannot create list entry $key; add it to an existing list.');
      nested = {key: nested};
    }
    return nested;
  }

  static Object? _plain(YamlNode node) => switch (node) {
    final YamlMap map => {
      for (final MapEntry(:key, :value) in map.nodes.entries) '${(key as YamlNode).value}': _plain(value),
    },
    final YamlList list => [for (final item in list.nodes) _plain(item)],
    _ => node.value,
  };

  static String _withNewline(String text) => text.isEmpty || text.endsWith('\n') ? text : '$text\n';
}

/// A value typed by a person, read as YAML: `30` is a number, `true` a
/// bool, `[a, b]` a list, `{a: 1}` a map, anything else text (`#3f51b5`
/// too, which YAML would read as a comment). Throws [InvalidInputException]
/// for broken YAML such as `[a`.
Object? parseConfigValue(String text) {
  final trimmed = text.trim();
  final Object? value;
  try {
    value = loadYaml(trimmed);
  } on YamlException catch (e) {
    throw InvalidInputException('"$trimmed" is not a YAML value: ${e.message}');
  }
  if (value == null && !const {'', 'null', '~'}.contains(trimmed)) return trimmed;
  return _plainValue(value);
}

/// [value] as [parseConfigValue] reads it back: text as is unless it would
/// read as something else, lists and maps in flow style.
String formatConfigValue(Object? value) => switch (value) {
  null => '',
  final String text when parseConfigValue(text) == text => text,
  final String text => jsonEncode(text),
  num() || bool() => '$value',
  _ => jsonEncode(value),
};

Object? _plainValue(Object? value) => switch (value) {
  final Map<Object?, Object?> map => {for (final MapEntry(:key, :value) in map.entries) '$key': _plainValue(value)},
  final List<Object?> list => [for (final item in list) _plainValue(item)],
  _ => value,
};

/// [path] as `a.b[0].c`.
String formatConfigPath(ConfigPath path) {
  final buffer = StringBuffer();
  for (final key in path) {
    if (key is int) {
      buffer.write('[$key]');
    } else {
      if (buffer.isNotEmpty) buffer.write('.');
      buffer.write(key);
    }
  }
  return buffer.toString();
}

/// Parses `a.b[0].c` (or `a.b.0.c`) into a [ConfigPath]. Throws
/// [InvalidInputException] for an empty path or an empty key.
ConfigPath parseConfigPath(String text) {
  final path = <Object>[];
  for (final part in text.trim().split('.')) {
    final match = RegExp(r'^([^\[\]]*)((?:\[\d+\])*)$').firstMatch(part);
    if (match == null) throw InvalidInputException('"$text" is not a key path like claims.lease_minutes.');
    final key = match[1]!;
    final indexes = RegExp(r'\[(\d+)\]').allMatches(match[2]!).map((m) => int.parse(m[1]!));
    if (key.isEmpty && indexes.isEmpty) {
      throw InvalidInputException('"$text" is not a key path like claims.lease_minutes.');
    }
    if (key.isNotEmpty) path.add(RegExp(r'^\d+$').hasMatch(key) && path.isNotEmpty ? int.parse(key) : key);
    path.addAll(indexes);
  }
  return path;
}
