import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../infrastructure/backlog_layout.dart';
import '../domain/item.dart';
import '../domain/item_id.dart';
import 'markdown_item_codec.dart';

/// The stamp of an item file and what reading it gave: the item, or the
/// problem that kept it from being one.
final class ItemCacheEntry {
  const ItemCacheEntry({
    required this.modified,
    required this.changed,
    required this.size,
    required this.item,
    required this.problem,
  });

  final DateTime modified;
  final DateTime changed;
  final int size;
  final Item? item;
  final String? problem;
}

/// Parsed item files kept between processes in `.cache/items.json` of the
/// backlog folder (`cache.items` in `backlog.yaml`), so that a short-lived
/// process such as the CLI does not parse every file again.
///
/// The files stay the only source of truth: an entry is only a shortcut for
/// a file whose stamp (modification time, change time and size) is the same
/// as when it was read, which [FileSystemItemRepository] checks before using
/// it. Whatever is in doubt — a missing, unreadable or damaged file, another
/// [schema], other item fields or other defaults for missing keys — makes
/// [read] return nothing, and the cache is built again. Deleting the folder
/// is always safe. The folder ignores itself in git (its own `.gitignore`).
final class ItemCacheFile {
  ItemCacheFile(BacklogLayout layout, this.defaults) : root = layout.root, path = p.join(layout.cacheDir, 'items.json');

  /// Bump whenever decoding an item file gives something else than before
  /// (the codec, [Item] or this format change), so that old caches are
  /// dropped. New front-matter fields drop them by themselves
  /// ([Item.fieldNames] is part of the key).
  static const schema = 1;

  /// The backlog folder; entries are keyed by paths relative to it.
  final String root;
  final ItemDefaults defaults;
  final String path;

  late final String _key = jsonEncode({
    'schema': schema,
    'fields': Item.fieldNames,
    'defaults': [defaults.type, defaults.status, defaults.priority],
  });

  /// The entries by absolute path; empty when the cache is missing or in
  /// doubt.
  Map<String, ItemCacheEntry> read() {
    try {
      final file = File(path);
      if (!file.existsSync()) return {};
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map<String, Object?> || jsonEncode(json['key']) != _key) return {};
      final files = json['files'] as Map<String, Object?>;
      return {
        for (final MapEntry(:key, :value) in files.entries) p.join(root, key): _entry(value as Map<String, Object?>),
      };
    } on Object {
      return {}; // in doubt: build it again
    }
  }

  /// Replaces the cache with [entries] (by absolute path). Entries that
  /// cannot be stored (e.g. a number YAML reads as infinity) are left out;
  /// a failed write leaves no cache rather than a broken one.
  void write(Map<String, ItemCacheEntry> entries) {
    final files = <String, Object?>{};
    for (final MapEntry(:key, :value) in entries.entries) {
      final json = _json(value);
      if (json != null) files[p.relative(key, from: root)] = json;
    }
    final file = File(path);
    final temp = File('$path.${pid}_${Random().nextInt(1 << 32)}.tmp');
    try {
      file.parent.createSync(recursive: true);
      final ignore = File(p.join(file.parent.path, '.gitignore'));
      if (!ignore.existsSync()) ignore.writeAsStringSync('# a cache of the backlog, never committed\n*\n');
      temp.writeAsStringSync('{"key":$_key,"files":${jsonEncode(files)}}');
      temp.renameSync(path);
    } on FileSystemException {
      for (final stale in [temp, file]) {
        try {
          if (stale.existsSync()) stale.deleteSync();
        } on FileSystemException {
          // nothing more to do; a damaged cache is dropped when read
        }
      }
    }
  }

  static Map<String, Object?>? _json(ItemCacheEntry entry) {
    final item = entry.item;
    if (item != null && item.extra.isNotEmpty) {
      try {
        jsonEncode(item.extra);
      } on JsonUnsupportedObjectError {
        return null;
      }
    }
    return {
      'm': entry.modified.microsecondsSinceEpoch,
      'c': entry.changed.microsecondsSinceEpoch,
      's': entry.size,
      if (item != null) 'item': _itemJson(item) else 'problem': entry.problem,
    };
  }

  static ItemCacheEntry _entry(Map<String, Object?> json) {
    final item = json['item'] as Map<String, Object?>?;
    return ItemCacheEntry(
      modified: DateTime.fromMicrosecondsSinceEpoch(json['m']! as int),
      changed: DateTime.fromMicrosecondsSinceEpoch(json['c']! as int),
      size: json['s']! as int,
      item: item == null ? null : _item(item),
      problem: item == null ? json['problem']! as String : null,
    );
  }

  static Map<String, Object?> _itemJson(Item item) => {
    'id': item.id.value,
    'title': item.title,
    'type': item.type,
    'status': item.status,
    'priority': item.priority,
    if (item.milestone != null) 'milestone': item.milestone,
    if (item.parent != null) 'parent': item.parent!.value,
    if (item.dependsOn.isNotEmpty) 'depends_on': [for (final id in item.dependsOn) id.value],
    if (item.related.isNotEmpty) 'related': [for (final id in item.related) id.value],
    if (item.assignee != null) 'assignee': item.assignee,
    if (item.branch != null) 'branch': item.branch,
    if (item.pr != null) 'pr': item.pr,
    if (item.labels.isNotEmpty) 'labels': item.labels,
    if (item.docs.isNotEmpty) 'docs': item.docs,
    if (item.touches.isNotEmpty) 'touches': item.touches,
    if (item.created != null) 'created': item.created,
    if (item.updated != null) 'updated': item.updated,
    if (item.extra.isNotEmpty) 'extra': item.extra,
    'body': item.body,
  };

  static Item _item(Map<String, Object?> json) {
    List<String> strings(String key) => [
      for (final value in (json[key] as List<Object?>?) ?? const []) value! as String,
    ];
    List<ItemId> ids(String key) => [for (final value in strings(key)) ItemId(value)];
    final parent = json['parent'] as String?;
    return Item(
      id: ItemId(json['id']! as String),
      title: json['title']! as String,
      type: json['type']! as String,
      status: json['status']! as String,
      priority: json['priority']! as String,
      milestone: json['milestone'] as String?,
      parent: parent == null ? null : ItemId(parent),
      dependsOn: ids('depends_on'),
      related: ids('related'),
      assignee: json['assignee'] as String?,
      branch: json['branch'] as String?,
      pr: json['pr'] as String?,
      labels: strings('labels'),
      docs: strings('docs'),
      touches: strings('touches'),
      created: json['created'] as String?,
      updated: json['updated'] as String?,
      extra: (json['extra'] as Map<String, Object?>?) ?? const {},
      body: json['body']! as String,
    );
  }
}
