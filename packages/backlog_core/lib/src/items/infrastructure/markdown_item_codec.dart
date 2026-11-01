import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../shared/errors.dart';
import '../domain/item.dart';
import '../domain/item_id.dart';
import 'front_matter.dart';

/// Values for keys an item file leaves out.
final class ItemDefaults {
  const ItemDefaults({required this.type, required this.status, required this.priority});

  final String type;
  final String status;
  final String priority;
}

/// Converts between [Item] and a Markdown file with YAML front matter.
///
/// [update] edits only the keys that changed, so comments, key order and
/// quoting a human chose survive, and git diffs stay one line per change.
final class MarkdownItemCodec {
  const MarkdownItemCodec(this.defaults);

  final ItemDefaults defaults;

  static const _equality = DeepCollectionEquality();

  Item decode(String text) {
    final document = FrontMatterDocument.parse(text);
    if (document.frontMatter == null) {
      throw const FormatException('missing YAML front matter (--- … ---)');
    }
    final Object? parsed;
    try {
      parsed = loadYaml(document.frontMatter!);
    } on YamlException catch (e) {
      throw FormatException('invalid YAML: ${e.message}');
    }
    if (parsed is! YamlMap) {
      throw const FormatException('front matter must be a mapping');
    }
    final yaml = parsed;

    String? optional(String key) => _scalar(yaml[key], key);
    String required(String key) => optional(key) ?? (throw FormatException('missing required field "$key"'));
    ItemId id(String value, String key) {
      try {
        return ItemId(value);
      } on InvalidInputException catch (e) {
        throw FormatException('$key: ${e.message}');
      }
    }

    try {
      return Item(
        id: id(required('id'), 'id'),
        title: required('title'),
        type: optional('type') ?? defaults.type,
        status: optional('status') ?? defaults.status,
        priority: optional('priority') ?? defaults.priority,
        rank: _number(yaml['rank'], 'rank'),
        milestone: optional('milestone'),
        parent: switch (optional('parent')) {
          null => null,
          final value => id(value, 'parent'),
        },
        dependsOn: _strings(yaml['depends_on'], 'depends_on').map((v) => id(v, 'depends_on')).toList(),
        related: _strings(yaml['related'], 'related').map((v) => id(v, 'related')).toList(),
        assignee: optional('assignee'),
        branch: optional('branch'),
        pr: optional('pr'),
        labels: _strings(yaml['labels'], 'labels'),
        docs: _strings(yaml['docs'], 'docs'),
        touches: _strings(yaml['touches'], 'touches'),
        created: optional('created'),
        updated: optional('updated'),
        extra: {
          for (final entry in yaml.entries)
            if (!Item.fieldNames.contains('${entry.key}')) '${entry.key}': _plain(entry.value),
        },
        body: document.body,
      );
    } on InvalidInputException catch (e) {
      throw FormatException(e.message);
    }
  }

  /// A fresh file for a new item, keys in canonical order.
  String encode(Item item) {
    final buffer = StringBuffer();
    _fields(item).forEach((key, value) {
      if (_isEmpty(value)) return;
      buffer.write(_emit(key, value, 0));
    });
    return FrontMatterDocument.compose(buffer.toString(), item.body);
  }

  /// Rewrites [original] so that it describes [item], touching as little as
  /// possible.
  String update(String original, Item item) {
    final document = FrontMatterDocument.parse(original);
    final previous = decode(original);
    if (previous.id != item.id) {
      throw StateError('Cannot turn ${previous.id} into ${item.id}.');
    }

    final editor = YamlEditor(document.frontMatter!);
    final before = _fields(previous);
    final after = _fields(item);
    final current = loadYaml(document.frontMatter!) as YamlMap;
    for (final key in {...before.keys, ...after.keys}) {
      final value = after[key];
      if (_equality.equals(before[key], value)) continue;
      if (_isEmpty(value)) {
        if (current.containsKey(key)) editor.remove([key]);
      } else if (value is String && _instant.hasMatch(value)) {
        editor.update([key], wrapAsYamlNode(value, scalarStyle: ScalarStyle.PLAIN));
      } else {
        editor.update([key], _node(value));
      }
    }

    var frontMatter = editor.toString();
    if (!frontMatter.endsWith('\n')) frontMatter = '$frontMatter\n';
    if (item.body == previous.body) {
      return frontMatter == document.frontMatter ? original : '---\n$frontMatter---\n${document.rawBody}';
    }
    return FrontMatterDocument.compose(frontMatter, item.body);
  }

  static Map<String, Object?> _fields(Item item) => {
    'id': item.id.value,
    'title': item.title,
    'type': item.type,
    'status': item.status,
    'priority': item.priority,
    'rank': item.rank,
    'milestone': item.milestone,
    'parent': item.parent?.value,
    'depends_on': [for (final id in item.dependsOn) id.value],
    'related': [for (final id in item.related) id.value],
    'assignee': item.assignee,
    'branch': item.branch,
    'pr': item.pr,
    'labels': item.labels,
    'docs': item.docs,
    'touches': item.touches,
    'created': item.created,
    'updated': item.updated,
    ...item.extra,
  };

  static bool _isEmpty(Object? value) =>
      value == null || (value is Iterable && value.isEmpty) || (value is Map && value.isEmpty);

  static Object? _node(Object? value) => value is List || value is Map
      ? wrapAsYamlNode(
          value,
          collectionStyle: value is List && value.every((v) => v is! List && v is! Map)
              ? CollectionStyle.FLOW
              : CollectionStyle.BLOCK,
        )
      : value;

  static String? _scalar(Object? value, String key) {
    if (value == null) return null;
    if (value is Map || value is List) {
      throw FormatException('"$key" must be a single value');
    }
    final text = '$value'.trim();
    return text.isEmpty ? null : text;
  }

  static num? _number(Object? value, String key) => switch (_scalar(value, key)) {
    null => null,
    final text => switch (num.tryParse(text)) {
      final number? when number.isFinite => number,
      _ => throw FormatException('"$key" must be a number, not "$text"'),
    },
  };

  static List<String> _strings(Object? value, String key) {
    if (value == null) return const [];
    if (value is List) {
      return value.map((v) => _scalar(v, key)).whereType<String>().toList();
    }
    final single = _scalar(value, key);
    return single == null ? const [] : [single];
  }

  static Object? _plain(Object? value) => switch (value) {
    final YamlMap map => {for (final e in map.entries) '${e.key}': _plain(e.value)},
    final YamlList list => [for (final v in list) _plain(v)],
    final YamlScalar scalar => scalar.value,
    _ => value,
  };

  static String _emit(String key, Object? value, int indent) {
    final pad = ' ' * indent;
    if (value is Map) {
      final nested = StringBuffer('$pad${_scalarText(key)}:\n');
      value.forEach((k, v) => nested.write(_emit('$k', v, indent + 2)));
      return nested.toString();
    }
    if (value is List && value.any((v) => v is Map || v is List)) {
      return '$pad${_scalarText(key)}: ${jsonEncode(value)}\n';
    }
    if (value is List) {
      return '$pad${_scalarText(key)}: [${value.map(_scalarText).join(', ')}]\n';
    }
    return '$pad${_scalarText(key)}: ${_scalarText(value)}\n';
  }

  static final _plainSafe = RegExp(
    r"^[\p{L}\p{N}_./()]([\p{L}\p{N} _./()'+&!?-]*[\p{L}\p{N}_./()'!?])?$",
    unicode: true,
  );
  static final _instant = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$');
  static const _reserved = {'true', 'false', 'yes', 'no', 'on', 'off', 'null', '~', 'y', 'n'};

  /// Plain when YAML reads it back as the same string, double-quoted otherwise.
  static String _scalarText(Object? value) {
    if (value == null) return 'null';
    if (value is bool || value is num) return '$value';
    final text = '$value';
    if (_instant.hasMatch(text)) return text;
    final plain = _plainSafe.hasMatch(text) && !_reserved.contains(text.toLowerCase()) && num.tryParse(text) == null;
    return plain ? text : jsonEncode(text);
  }
}
