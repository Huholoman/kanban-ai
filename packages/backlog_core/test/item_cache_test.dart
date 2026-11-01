import 'dart:convert';
import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_core/src/items/infrastructure/file_system_item_repository.dart';
import 'package:backlog_core/src/items/infrastructure/item_cache_file.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The in-memory cache of [FileSystemItemRepository] (used by the server):
/// whatever happens to the files, a load returns what is on disk.
void main() {
  group('in memory', memoryCacheTests);
  group('persistent', persistentCacheTests);
}

void memoryCacheTests() {
  late Directory dir;
  late BacklogLayout layout;
  const codec = MarkdownItemCodec(ItemDefaults(type: 'task', status: 'todo', priority: 'p2'));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('backlog_cache_');
    layout = BacklogLayout(dir.path);
    await Directory(layout.itemsDir).create(recursive: true);
  });

  tearDown(() => dir.delete(recursive: true));

  File file(String name) => File(p.join(layout.itemsDir, name));

  void write(String name, String id, String title) =>
      file(name).writeAsStringSync('---\nid: $id\ntitle: $title\n---\n\nBody of $id.\n');

  Future<Map<String, String>> titles(FileSystemItemRepository repository) async => {
    for (final item in (await repository.load()).items) item.id.value: item.title,
  };

  FileSystemItemRepository cached({Duration settle = const Duration(seconds: 3)}) =>
      FileSystemItemRepository(layout, codec, cache: true, settle: settle);

  test('unchanged files are not parsed again', () async {
    write('T-1-a.md', 'T-1', 'A');
    write('T-2-b.md', 'T-2', 'B');
    final repository = cached();
    expect(await titles(repository), {'T-1': 'A', 'T-2': 'B'});
    expect(repository.parsed, 2);
    expect(await titles(repository), {'T-1': 'A', 'T-2': 'B'});
    expect(repository.parsed, 2, reason: 'just written files are read again, but parsed only when their text changed');

    final settled = cached(settle: Duration.zero);
    await settled.load();
    await settled.load();
    expect(settled.parsed, 2);
  });

  test('a change from outside is seen, also with the same size within the same millisecond', () async {
    write('T-1-a.md', 'T-1', 'A');
    final repository = cached();
    expect(await titles(repository), {'T-1': 'A'});
    for (final title in ['B', 'C', 'D']) {
      write('T-1-a.md', 'T-1', title); // same size, usually the same mtime
      expect(await titles(repository), {'T-1': title});
    }
  });

  test('a file with a trusted stamp is seen when it changes later', () async {
    write('T-1-a.md', 'T-1', 'A');
    final repository = cached(settle: Duration.zero);
    expect(await titles(repository), {'T-1': 'A'});
    await Future<void>.delayed(const Duration(milliseconds: 20)); // a later mtime
    write('T-1-a.md', 'T-1', 'B');
    expect(await titles(repository), {'T-1': 'B'});
  });

  test('restoring the old modification time does not hide a change (ctime)', () async {
    write('T-1-a.md', 'T-1', 'A');
    final old = DateTime.now().subtract(const Duration(minutes: 1));
    file('T-1-a.md').setLastModifiedSync(old);
    final repository = cached(settle: Duration.zero);
    expect(await titles(repository), {'T-1': 'A'});
    await Future<void>.delayed(const Duration(milliseconds: 20)); // a later ctime
    write('T-1-a.md', 'T-1', 'B');
    file('T-1-a.md').setLastModifiedSync(old); // like `touch -r` or rsync -t
    expect(await titles(repository), {'T-1': 'B'});
  });

  test('new, deleted and renamed files', () async {
    write('T-1-a.md', 'T-1', 'A');
    write('T-2-b.md', 'T-2', 'B');
    final repository = cached(settle: Duration.zero);
    expect(await titles(repository), {'T-1': 'A', 'T-2': 'B'});

    write('T-3-c.md', 'T-3', 'C');
    file('T-2-b.md').deleteSync();
    file('T-1-a.md').renameSync(file('T-1-renamed.md').path);
    expect(await titles(repository), {'T-1': 'A', 'T-3': 'C'});
    expect(await repository.locationOf(ItemId('T-1')), file('T-1-renamed.md').path);

    Directory(p.join(layout.itemsDir, 'T-1-folder')).createSync();
    file('T-1-renamed.md').renameSync(p.join(layout.itemsDir, 'T-1-folder', 'index.md'));
    expect(await titles(repository), {'T-1': 'A', 'T-3': 'C'});
    expect(await repository.locationOf(ItemId('T-1')), p.join(layout.itemsDir, 'T-1-folder', 'index.md'));
  });

  test('own writes are seen even when the stamps are trusted blindly', () async {
    write('T-1-a.md', 'T-1', 'A');
    // A negative settle trusts every stamp at once, so a save landing in the
    // same millisecond with the same size relies on save dropping the file.
    final repository = cached(settle: const Duration(days: -1));
    final item = (await repository.load()).items.single;
    for (final title in ['B', 'C', 'D']) {
      await repository.save(item.copyWith(title: title)); // same size, likely the same mtime
      expect(await titles(repository), {'T-1': title});
    }
    await repository.save(Item(id: ItemId('T-2'), title: 'New', type: 'task', status: 'todo', priority: 'p2'));
    expect(await titles(repository), {'T-1': 'D', 'T-2': 'New'});
  });

  test('broken files are reported until they are fixed', () async {
    write('T-1-a.md', 'T-1', 'A');
    file('T-2-b.md').writeAsStringSync('no front matter');
    final repository = cached();
    var catalog = await repository.load();
    expect(catalog.problems.single.location, 'items/T-2-b.md');
    catalog = await repository.load();
    expect(catalog.problems.single.location, 'items/T-2-b.md');

    write('T-2-b.md', 'T-2', 'B');
    catalog = await repository.load();
    expect(catalog.problems, isEmpty);
    expect(catalog.items.map((i) => i.id.value), ['T-1', 'T-2']);
  });
}

/// The persistent cache (`cache.items`): each repository stands for a new
/// process starting from `.cache/items.json`.
void persistentCacheTests() {
  late Directory dir;
  late BacklogLayout layout;
  const defaults = ItemDefaults(type: 'task', status: 'todo', priority: 'p2');
  const codec = MarkdownItemCodec(defaults);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('backlog_persistent_');
    layout = BacklogLayout(dir.path);
    await Directory(layout.itemsDir).create(recursive: true);
  });

  tearDown(() => dir.delete(recursive: true));

  File file(String name) => File(p.join(layout.itemsDir, name));
  File cacheFile() => File(p.join(layout.root, '.cache', 'items.json'));

  void write(String name, String id, String title) =>
      file(name).writeAsStringSync('---\nid: $id\ntitle: $title\n---\n\nBody of $id.\n');

  /// A process with its own repository; [settle] zero trusts what was
  /// written before the load at once.
  FileSystemItemRepository process({
    MarkdownItemCodec codec = codec,
    Duration settle = Duration.zero,
    bool cache = false,
  }) => FileSystemItemRepository(
    layout,
    codec,
    cache: cache,
    persistent: ItemCacheFile(layout, codec.defaults),
    settle: settle,
  );

  Future<Map<String, String>> titles(FileSystemItemRepository repository) async => {
    for (final item in (await repository.load()).items) item.id.value: item.title,
  };

  test('a new process takes unchanged files from the cache, with every field', () async {
    file('T-1-a.md').writeAsStringSync('''
---
id: T-1
title: Everything
type: bug
status: done
priority: p0
milestone: v1
parent: T-9
depends_on: [T-2, T-3]
related: [T-4]
assignee: wt-2
branch: agent/T-1
pr: https://example.com/pulls/1
labels: [ui, "a b"]
docs: [design.md]
touches: [lib/]
created: 2026-01-01
updated: 2026-01-02T10:00:00Z
estimate: 3
ratio: 1.5
done_by: null
flag: true
nested: {a: [1, {b: c}]}
---

Body.

- [ ] one
''');
    file('T-2-b.md').writeAsStringSync('no front matter');
    write('T-3-c.md', 'T-3', 'Plain');
    final first = process();
    final expected = await first.load();
    expect(first.parsed, 3);
    expect(cacheFile().existsSync(), isTrue);
    expect(File(p.join(layout.root, '.cache', '.gitignore')).readAsStringSync(), contains('*'));

    final second = process();
    final catalog = await second.load();
    expect(second.parsed, 0);
    expect(catalog.problems.map((p) => '$p'), expected.problems.map((p) => '$p'));
    expect(catalog.items, hasLength(2));
    for (final [actual, wanted] in IterableZip([catalog.items, expected.items])) {
      expect(codec.encode(actual), codec.encode(wanted));
      expect(actual.extra, wanted.extra);
      expect(actual.body, wanted.body);
    }
    expect(catalog.items.first.extra['ratio'], 1.5);
  });

  test('files changed, added or deleted since are read again', () async {
    write('T-1-a.md', 'T-1', 'A');
    write('T-2-b.md', 'T-2', 'B');
    await process().load();

    await Future<void>.delayed(const Duration(milliseconds: 20)); // later stamps
    write('T-1-a.md', 'T-1', 'X'); // same size
    file('T-2-b.md').deleteSync();
    write('T-3-c.md', 'T-3', 'C');
    final second = process();
    expect(await titles(second), {'T-1': 'X', 'T-3': 'C'});
    expect(second.parsed, 2);

    final third = process();
    expect(await titles(third), {'T-1': 'X', 'T-3': 'C'});
    expect(third.parsed, 0);
  });

  test('recently changed files are not kept, so a change in the same tick is never missed', () async {
    write('T-1-a.md', 'T-1', 'A');
    expect(await titles(process(settle: const Duration(seconds: 3))), {'T-1': 'A'});
    write('T-1-a.md', 'T-1', 'B'); // same size, likely the same mtime
    final second = process(settle: const Duration(seconds: 3));
    expect(await titles(second), {'T-1': 'B'});
    expect(second.parsed, 1);
  });

  test('other defaults, another format or a damaged file: built again', () async {
    file('T-1-a.md').writeAsStringSync('---\nid: T-1\ntitle: A\n---\n');
    expect((await process().load()).items.single.status, 'todo');

    final other = process(
      codec: const MarkdownItemCodec(ItemDefaults(type: 'task', status: 'backlog', priority: 'p2')),
    );
    expect((await other.load()).items.single.status, 'backlog');
    expect(other.parsed, 1);

    for (final damaged in ['{"key": 1', '[]', '{"key": {"schema": 0}, "files": {}}', '']) {
      cacheFile().writeAsStringSync(damaged);
      final repository = process();
      expect((await repository.load()).items.single.status, 'todo');
      expect(repository.parsed, 1, reason: damaged);
    }
    final valid = jsonDecode(cacheFile().readAsStringSync()) as Map<String, Object?>;
    ((valid['files']! as Map<String, Object?>)['items/T-1-a.md']! as Map<String, Object?>)['item'] = {'id': 'T-1'};
    cacheFile().writeAsStringSync(jsonEncode(valid));
    final repository = process();
    expect((await repository.load()).items.single.title, 'A');
    expect(repository.parsed, 1);
  });

  test('deleting the cache is safe', () async {
    write('T-1-a.md', 'T-1', 'A');
    await process().load();
    Directory(p.join(layout.root, '.cache')).deleteSync(recursive: true);
    final repository = process();
    expect(await titles(repository), {'T-1': 'A'});
    expect(repository.parsed, 1);
    expect(cacheFile().existsSync(), isTrue);
  });

  test('values JSON cannot hold are parsed every time instead', () async {
    file('T-1-a.md').writeAsStringSync('---\nid: T-1\ntitle: A\nodd: .inf\n---\n');
    write('T-2-b.md', 'T-2', 'B');
    await process().load();
    final repository = process();
    final items = (await repository.load()).items;
    expect(items.first.extra['odd'], double.infinity);
    expect(repository.parsed, 1);
  });

  test('a long-running process writes the cache only when what it trusts changes', () async {
    write('T-1-a.md', 'T-1', 'A');
    final server = process(cache: true);
    await server.load();
    final written = cacheFile().lastModifiedSync();
    cacheFile().setLastModifiedSync(written.subtract(const Duration(minutes: 1)));
    await server.load();
    expect(cacheFile().lastModifiedSync(), written.subtract(const Duration(minutes: 1)));

    write('T-2-b.md', 'T-2', 'B');
    await server.load();
    final next = process();
    expect(await titles(next), {'T-1': 'A', 'T-2': 'B'});
    expect(next.parsed, 0);
  });
}
