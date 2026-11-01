import 'dart:io';

import 'package:path/path.dart' as p;

import '../../infrastructure/backlog_layout.dart';
import '../../shared/slug.dart';
import '../domain/item.dart';
import '../domain/item_id.dart';
import '../domain/item_repository.dart';
import 'item_cache_file.dart';
import 'markdown_item_codec.dart';

/// Items as `items/<id>-<slug>.md`, or `items/<id>-<slug>/index.md` when an
/// item needs attachments next to it.
///
/// The id inside the front matter is the source of truth; the file name is
/// only a convenience and is never renamed.
///
/// With [cache] (for long-running processes such as the server) the parsed
/// files are kept in memory and [load] parses again only what changed. Every
/// [load] still lists the folder and `stat`s each file, so changes made by
/// anyone (agents, editors, `git checkout`, renames, deletions) are seen
/// without a watcher. A cached file is reused only when its modification
/// time, change time (ctime) and size are the same as when it was read, and
/// both times were at least [settle] older than that read: file times have a
/// coarse resolution (milliseconds in Dart, up to 2 s on some file systems),
/// so a file written again in the same tick with the same size keeps its
/// stamp. Such a recently changed file is read again on every load until it
/// settles and parsed again only when its text differs. Writes through [save]
/// drop the file from the cache.
///
/// With a [persistent] cache file the files whose stamp was trusted are also
/// kept there: the first [load] starts from it, and a load that changed what
/// is trusted writes it again. It works with or without [cache] (the CLI
/// without, so that each process starts from the file).
final class FileSystemItemRepository implements ItemRepository {
  FileSystemItemRepository(
    this._layout,
    this._codec, {
    bool cache = false,
    this.persistent,
    this.settle = const Duration(seconds: 3),
  }) : _cache = cache || persistent != null ? {} : null;

  final BacklogLayout _layout;
  final MarkdownItemCodec _codec;
  final Map<ItemId, String> _paths = {};

  /// Parsed files by path; null without caching.
  final Map<String, _CachedFile>? _cache;

  /// Where trusted files are kept between processes; null when not.
  final ItemCacheFile? persistent;
  bool _seeded = false;

  /// Whether the trusted files of [_cache] differ from those in [persistent].
  bool _dirty = false;

  /// How much older than the read a file's times must be for its stamp to be
  /// trusted (see the class documentation).
  final Duration settle;

  /// Files parsed since this repository was created (for tests and
  /// diagnostics of the cache).
  int get parsed => _parsed;
  int _parsed = 0;

  /// Reads every item file (only the changed ones with [cache]).
  ///
  /// Listing and reading are synchronous on purpose: for thousands of small
  /// files the asynchronous calls cost several times more than the reading
  /// itself (5 000 items: ~0.9 s file by file, ~0.45 s all at once, ~0.1 s
  /// synchronously), and the decoding that follows blocks the isolate anyway.
  /// Being synchronous, a load also cannot interleave with another one.
  @override
  Future<ItemCatalog> load() async {
    final items = <Item>[];
    final problems = <LoadProblem>[];
    _paths.clear();
    final cache = _cache;
    final persistent = this.persistent;
    if (cache != null && persistent != null && !_seeded) {
      _seeded = true;
      for (final MapEntry(:key, :value) in persistent.read().entries) {
        cache[key] = _CachedFile.stored(value);
      }
    }
    final List<File> files;
    try {
      files = _itemFiles();
    } on FileSystemException {
      cache?.clear(); // unsure what is there: start over next time
      rethrow;
    }
    final readAt = DateTime.now();
    for (final file in files) {
      final (item, problem) = cache == null ? _uncached(file) : _cached(cache, file, readAt);
      if (item != null) {
        items.add(item);
        _paths.putIfAbsent(item.id, () => file.path);
      } else if (problem != null) {
        problems.add(LoadProblem(_layout.relative(file.path), problem));
      }
    }
    if (cache != null && cache.length > files.length) {
      final present = {for (final file in files) file.path};
      cache.removeWhere((path, cached) {
        final gone = !present.contains(path);
        if (gone && cached.trusted) _dirty = true;
        return gone;
      });
    }
    if (cache != null && persistent != null && _dirty) {
      _dirty = false;
      persistent.write({
        for (final MapEntry(:key, :value) in cache.entries)
          if (value.trusted) key: value.entry,
      });
    }
    return ItemCatalog(items, problems);
  }

  (Item?, String?) _uncached(File file) {
    try {
      return _parse(file.readAsStringSync());
    } on FileSystemException catch (e) {
      return (null, e.message);
    }
  }

  /// The item or the problem of one file, from the cache when its stamp says
  /// it is unchanged.
  (Item?, String?) _cached(Map<String, _CachedFile> cache, File file, DateTime readAt) {
    final cached = cache[file.path];
    final FileStat stat;
    final String text;
    try {
      stat = file.statSync();
      if (stat.type == FileSystemEntityType.notFound) throw FileSystemException('Cannot read file', file.path);
      if (cached != null && cached.trusted && cached.sameStamp(stat)) return cached.result;
      text = file.readAsStringSync();
    } on FileSystemException catch (e) {
      if (cache.remove(file.path)?.trusted ?? false) _dirty = true;
      return (null, e.message);
    }
    final result = cached != null && cached.text == text ? cached.result : _parse(text);
    final read = _CachedFile(stat, text, result, trusted: _settled(stat, readAt));
    if (read.trusted || (cached?.trusted ?? false)) _dirty = true;
    cache[file.path] = read;
    return result;
  }

  bool _settled(FileStat stat, DateTime readAt) {
    final latest = stat.modified.isAfter(stat.changed) ? stat.modified : stat.changed;
    return readAt.difference(latest) > settle;
  }

  (Item?, String?) _parse(String text) {
    _parsed++;
    try {
      return (_codec.decode(text), null);
    } on FormatException catch (e) {
      return (null, e.message);
    }
  }

  @override
  Future<void> save(Item item) async {
    var path = _paths[item.id];
    if (path == null || !File(path).existsSync()) {
      await load();
      path = _paths[item.id];
    }
    final file = File(path ?? p.join(_layout.itemsDir, _fileName(item)));
    final content = path == null ? _codec.encode(item) : _codec.update(await file.readAsString(), item);
    _cache?.remove(file.path);
    await writeAtomically(file, content);
    _cache?.remove(file.path);
    _paths[item.id] = file.path;
  }

  @override
  Future<String?> locationOf(ItemId id) async {
    if (!_paths.containsKey(id)) await load();
    return _paths[id];
  }

  List<File> _itemFiles() {
    final dir = Directory(_layout.itemsDir);
    if (!dir.existsSync()) return const [];
    final files = <File>[];
    for (final entity in dir.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      if (entity is File && name.endsWith('.md')) {
        files.add(entity);
      } else if (entity is Directory) {
        final index = File(p.join(entity.path, 'index.md'));
        if (index.existsSync()) files.add(index);
      }
    }
    return files..sort((a, b) => a.path.compareTo(b.path));
  }

  static String _fileName(Item item) {
    final slug = slugify(item.title);
    return slug.isEmpty ? '${item.id}.md' : '${item.id}-$slug.md';
  }
}

/// One parsed file and the stamp it had when it was read.
final class _CachedFile {
  _CachedFile(FileStat stat, this.text, this.result, {required this.trusted})
    : modified = stat.modified,
      changed = stat.changed,
      size = stat.size;

  /// From the persistent cache: trusted when it was written, without text.
  _CachedFile.stored(ItemCacheEntry entry)
    : modified = entry.modified,
      changed = entry.changed,
      size = entry.size,
      text = null,
      result = (entry.item, entry.problem),
      trusted = true;

  final DateTime modified;
  final DateTime changed;
  final int size;

  /// The text read; null for an entry of the persistent cache.
  final String? text;
  final (Item?, String?) result;

  ItemCacheEntry get entry =>
      ItemCacheEntry(modified: modified, changed: changed, size: size, item: result.$1, problem: result.$2);

  /// The times were settled when the file was read, so any later write
  /// changes the stamp.
  final bool trusted;

  bool sameStamp(FileStat stat) => stat.size == size && stat.modified == modified && stat.changed == changed;
}
