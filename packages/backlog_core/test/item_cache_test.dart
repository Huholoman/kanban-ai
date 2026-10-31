import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_core/src/items/infrastructure/file_system_item_repository.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The in-memory cache of [FileSystemItemRepository] (used by the server):
/// whatever happens to the files, a load returns what is on disk.
void main() {
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
