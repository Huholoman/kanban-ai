import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../../infrastructure/backlog_layout.dart';
import '../../items/infrastructure/slug.dart';
import '../../shared/errors.dart';
import '../domain/filter.dart';
import '../domain/view.dart';
import 'yaml_writer.dart';

/// Views as `views/<id>.yaml`:
///
/// ```yaml
/// name: Launch board
/// section: Releases         # optional heading in the app's view list
/// layout: kanban            # list | kanban | table | graph
/// filter:
///   milestone: launch
///   status: {not: [cancelled]}
///   or:
///     - priority: [p0, p1]
///     - labels: security
/// group_by: status
/// columns: [todo, in-progress, review, done]
/// sort: [priority, -updated]
/// ```
final class YamlViewRepository implements ViewRepository {
  YamlViewRepository(this._layout);

  final BacklogLayout _layout;

  @override
  Future<ViewCatalog> load() async {
    final dir = Directory(_layout.viewsDir);
    if (!await dir.exists()) return const ViewCatalog([]);
    final files = await dir
        .list()
        .where((e) => e is File && (e.path.endsWith('.yaml') || e.path.endsWith('.yml')))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));

    final views = <ViewDefinition>[];
    final problems = <(String, String)>[];
    for (final file in files) {
      final id = p.basenameWithoutExtension(file.path);
      try {
        views.add(parseViewYaml(id, await file.readAsString()));
      } on ConfigurationException catch (e) {
        problems.add((_layout.relative(file.path), e.message));
      }
    }
    return ViewCatalog(views, problems);
  }

  @override
  Future<void> setSection(String id, String? section) => _edit(id, (source) => withSection(source, section));

  @override
  Future<void> setColumns(String id, List<String>? columns) => _edit(id, (source) => withColumns(source, columns));

  @override
  Future<Map<String, Object?>> raw(String id) async {
    final source = await (await _file(id)).readAsString();
    return _plain(loadYaml(source)) as Map<String, Object?>;
  }

  @override
  Future<String> create(String preferredId, Map<String, Object?> definition) async {
    final source = toYaml(definition);
    final base = slugify(preferredId).isEmpty ? 'view' : slugify(preferredId);
    parseViewYaml(base, source); // never write what could not be read back
    await Directory(_layout.viewsDir).create(recursive: true);
    for (var n = 1; ; n++) {
      final id = n == 1 ? base : '$base-$n';
      final file = File(p.join(_layout.viewsDir, '$id.yaml'));
      if (file.existsSync() || File(p.join(_layout.viewsDir, '$id.yml')).existsSync()) continue;
      await writeAtomically(file, source);
      return id;
    }
  }

  /// Rewrites the file of view [id] through [change], keeping the rest.
  Future<void> _edit(String id, String Function(String source) change) async {
    final file = await _file(id);
    final source = await file.readAsString();
    parseViewYaml(id, source); // refuse to touch a broken definition
    await writeAtomically(file, change(source));
  }

  Future<File> _file(String id) async {
    // Only ids of existing views, so that no path can be smuggled in.
    if (!(await load()).views.any((view) => view.id == id)) throw NotFoundException('No view "$id".');
    final file = [
      for (final extension in ['yaml', 'yml']) File(p.join(_layout.viewsDir, '$id.$extension')),
    ].where((file) => file.existsSync()).firstOrNull;
    return file ?? (throw NotFoundException('No view "$id".'));
  }

  static Object? _plain(Object? node) => switch (node) {
    final YamlMap map => {for (final MapEntry(:key, :value) in map.entries) '$key': _plain(value)},
    final YamlList list => [for (final value in list) _plain(value)],
    _ => node,
  };
}

/// [source] with its `section` key set, or removed when [section] is null or
/// blank; comments and the other keys are kept.
String withSection(String source, String? section) {
  final value = section?.trim() ?? '';
  return _withKey(source, 'section', value.isEmpty ? null : value);
}

/// [source] with its `columns` set (as a flow list), or removed when
/// [columns] is null or empty so that the view shows its default groups.
String withColumns(String source, List<String>? columns) {
  final values = [
    for (final column in columns ?? const <String>[])
      if (column.trim().isNotEmpty) column.trim(),
  ];
  if (values.toSet().length != values.length) throw const InvalidInputException('Columns must not repeat.');
  return _withKey(
    source,
    'columns',
    values.isEmpty ? null : wrapAsYamlNode(values, collectionStyle: CollectionStyle.FLOW),
  );
}

String _withKey(String source, String key, Object? value) {
  final editor = YamlEditor(source);
  final present = (loadYaml(source) as YamlMap).containsKey(key);
  if (value == null) {
    if (present) editor.remove([key]);
  } else {
    editor.update([key], value);
  }
  return editor.toString();
}

ViewDefinition parseViewYaml(String id, String source) {
  final Object? yaml;
  try {
    yaml = loadYaml(source);
  } on YamlException catch (e) {
    throw ConfigurationException(e.message);
  }
  if (yaml is! YamlMap) throw const ConfigurationException('A view must be a mapping.');

  final layoutName = '${yaml['layout'] ?? 'list'}';
  final layout =
      ViewLayout.tryParse(layoutName) ??
      (throw ConfigurationException(
        'Unknown layout "$layoutName" (expected ${ViewLayout.values.map((l) => l.name).join(', ')}).',
      ));

  return ViewDefinition(
    id: id,
    name: '${yaml['name'] ?? id}',
    layout: layout,
    filter: yaml['filter'] == null ? Filter.all : parseFilter(yaml['filter']),
    groupBy: yaml['group_by']?.toString(),
    columns: yaml['columns'] == null ? null : _strings(yaml['columns'], 'columns'),
    sort: yaml['sort'] == null ? const [] : _strings(yaml['sort'], 'sort').map(SortKey.parse).toList(),
    fields: yaml['fields'] == null ? const [] : _strings(yaml['fields'], 'fields'),
    section: switch ('${yaml['section'] ?? ''}'.trim()) {
      '' => null,
      final section => section,
    },
  );
}

/// Filter expression grammar (YAML):
/// - a mapping is an AND of its entries;
/// - `and: [...]`, `or: [...]`, `not: <expr>` combine expressions;
/// - `field: value` / `field: [a, b]` match any of the values;
/// - `field: {not: ...}`, `{in: [...]}`, `{exists: bool}` and
///   `{contains: text}` (substring, ignoring case) refine it.
Filter parseFilter(Object? node) {
  if (node is List) return AllOf(node.map(parseFilter).toList());
  if (node is! Map) throw ConfigurationException('Cannot read filter "$node".');

  final parts = <Filter>[];
  node.forEach((key, value) {
    switch ('$key') {
      case 'and':
        parts.add(AllOf(_list(value, 'and').map(parseFilter).toList()));
      case 'or':
        parts.add(AnyOf(_list(value, 'or').map(parseFilter).toList()));
      case 'not':
        parts.add(Not(parseFilter(value)));
      case final field:
        parts.add(_fieldFilter(field, value));
    }
  });
  return parts.length == 1 ? parts.single : AllOf(parts);
}

Filter _fieldFilter(String field, Object? value) {
  if (value is! Map) return FieldIn(field, _values(value));
  final parts = <Filter>[];
  value.forEach((operator, operand) {
    switch ('$operator') {
      case 'in':
        parts.add(FieldIn(field, _values(operand)));
      case 'not':
        parts.add(Not(FieldIn(field, _values(operand))));
      case 'exists':
        parts.add(FieldExists(field, exists: operand == true));
      case 'contains':
        parts.add(FieldContains(field, '$operand'));
      case final other:
        throw ConfigurationException('Unknown operator "$other" for field "$field".');
    }
  });
  return parts.length == 1 ? parts.single : AllOf(parts);
}

List<String> _values(Object? value) => switch (value) {
  null => const [''],
  final List<Object?> list => [for (final v in list) '$v'],
  _ => ['$value'],
};

List<Object?> _list(Object? value, String key) =>
    value is List ? value : throw ConfigurationException('"$key" expects a list.');

List<String> _strings(Object? value, String key) => switch (value) {
  final List<Object?> list => [for (final v in list) '$v'],
  final String single => [single],
  _ => throw ConfigurationException('"$key" expects a list.'),
};

/// Views written by `backlog init`.
const defaultViews = {
  'board': '''
name: Board
layout: kanban
filter:
  type: {not: [epic]}
group_by: status
columns: [todo, in-progress, review, done]
sort: [priority, created]
''',
  'ready': '''
name: Ready to pick up
layout: list
filter:
  ready: true
sort: [priority, created]
''',
  'hot': '''
name: What's on fire
layout: list
filter:
  priority: [p0, p1]
  category: {not: [done]}
sort: [priority, status]
''',
  'blocked': '''
name: Blocked
layout: list
filter:
  blocked: true
''',
  'dependencies': '''
name: Dependencies
layout: graph
filter:
  category: {not: [done]}
''',
};
