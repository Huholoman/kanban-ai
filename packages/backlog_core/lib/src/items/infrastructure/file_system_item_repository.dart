import 'dart:io';

import 'package:path/path.dart' as p;

import '../../infrastructure/backlog_layout.dart';
import '../../shared/slug.dart';
import '../domain/item.dart';
import '../domain/item_id.dart';
import '../domain/item_repository.dart';
import 'markdown_item_codec.dart';

/// Items as `items/<id>-<slug>.md`, or `items/<id>-<slug>/index.md` when an
/// item needs attachments next to it.
///
/// The id inside the front matter is the source of truth; the file name is
/// only a convenience and is never renamed.
final class FileSystemItemRepository implements ItemRepository {
  FileSystemItemRepository(this._layout, this._codec);

  final BacklogLayout _layout;
  final MarkdownItemCodec _codec;
  final Map<ItemId, String> _paths = {};

  /// Reads every item file.
  ///
  /// Listing and reading are synchronous on purpose: for thousands of small
  /// files the asynchronous calls cost several times more than the reading
  /// itself (5 000 items: ~0.9 s file by file, ~0.45 s all at once, ~0.1 s
  /// synchronously), and the decoding that follows blocks the isolate anyway.
  @override
  Future<ItemCatalog> load() async {
    final items = <Item>[];
    final problems = <LoadProblem>[];
    _paths.clear();
    for (final file in _itemFiles()) {
      try {
        final item = _codec.decode(file.readAsStringSync());
        items.add(item);
        _paths.putIfAbsent(item.id, () => file.path);
      } on FormatException catch (e) {
        problems.add(LoadProblem(_layout.relative(file.path), e.message));
      } on FileSystemException catch (e) {
        problems.add(LoadProblem(_layout.relative(file.path), e.message));
      }
    }
    return ItemCatalog(items, problems);
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
    await writeAtomically(file, content);
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
