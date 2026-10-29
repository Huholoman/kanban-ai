import 'dart:io';
import 'dart:isolate';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('init and locate', () {
    test('init writes config, views and gitignore; refuses to run twice', () async {
      final (backlog, _) = await tempBacklog();
      expect(File(p.join(backlog.root, 'backlog.yaml')).existsSync(), isTrue);
      expect((await backlog.views.all()).map((v) => v.id), containsAll(['board', 'ready', 'hot']));
      expect(File(p.join(backlog.root, '.gitignore')).readAsStringSync(), contains('.locks/'));
      expect(() => Backlog.init(backlog.root), throwsA(isA<InvalidInputException>()));
    });

    test('locate finds the backlog from inside it and from a sibling worktree', () async {
      final dir = await Directory.systemTemp.createTemp('backlog_locate_');
      addTearDown(() => dir.delete(recursive: true));
      await Backlog.init(p.join(dir.path, 'backlog'));
      final worktree = await Directory(p.join(dir.path, 'monorepo-2', 'src', 'deep')).create(recursive: true);
      expect(Backlog.locate(worktree.path), p.join(dir.path, 'backlog'));
      expect(Backlog.locate(p.join(dir.path, 'backlog', 'items')), p.join(dir.path, 'backlog'));
    });

    test('open fails clearly outside a backlog', () async {
      final dir = await Directory.systemTemp.createTemp('backlog_none_');
      addTearDown(() => dir.delete(recursive: true));
      expect(() => Backlog.open(dir.path), throwsA(isA<NotFoundException>()));
    });
  });

  group('items', () {
    test('create writes a readable file named after id and title', () async {
      final (backlog, _) = await tempBacklog();
      final epic = await backlog.items.create(const NewItem(title: 'Data security', type: 'epic'));
      final task = await backlog.items.create(
        NewItem(
          title: 'Zürich DB backups',
          priority: 'p0',
          parent: epic.id.value,
          labels: const ['infra'],
          body: '## Context\n\nNothing yet.',
        ),
      );

      final path = await backlog.items.locate(task.id.value);
      expect(p.basename(path!), 'T-0002-zurich-db-backups.md');
      final text = File(path).readAsStringSync();
      expect(text, contains('parent: T-0001'));
      expect(text, contains('created: 2026-10-29'));
      expect((await backlog.items.get('0002')).labels, ['infra']);
    });

    test('create validates against the workflow and resolves references', () async {
      final (backlog, _) = await tempBacklog();
      expect(
        () => backlog.items.create(const NewItem(title: 'x', status: 'doing')),
        throwsA(isA<InvalidInputException>()),
      );
      expect(
        () => backlog.items.create(const NewItem(title: 'x', dependsOn: ['nope'])),
        throwsA(isA<NotFoundException>()),
      );
      expect(() => backlog.items.create(const NewItem(title: '  ')), throwsA(isA<InvalidInputException>()));
    });

    test('update applies changes, bumps updated and keeps hand edits', () async {
      final (backlog, clock) = await tempBacklog();
      final a = await backlog.items.create(const NewItem(title: 'A'));
      final b = await backlog.items.create(const NewItem(title: 'B'));
      final path = (await backlog.items.locate(b.id.value))!;
      File(path).writeAsStringSync('\nHand-written notes.\n', mode: FileMode.append);

      clock.advance(const Duration(days: 1));
      final updated = await backlog.items.update('0002', [
        FieldChange.parse('depends_on+=${a.id}'),
        FieldChange.parse('labels=x, y'),
        FieldChange.parse('labels-=x'),
        FieldChange.parse('estimate=2d'),
      ]);
      expect(updated.dependsOn, [a.id]);
      expect(updated.labels, ['y']);
      expect(updated.extra['estimate'], '2d');
      expect(updated.updated, '2026-10-30');
      expect(File(path).readAsStringSync(), contains('Hand-written notes.'));

      expect(
        () => backlog.items.update('0002', [FieldChange.parse('depends_on+=0002')]),
        throwsA(isA<InvalidInputException>()),
      );
      expect(() => backlog.items.update('0002', [FieldChange.parse('id=T-9')]), throwsA(isA<InvalidInputException>()));
      expect(
        () => backlog.items.update('0002', [FieldChange.parse('priority=p9')]),
        throwsA(isA<InvalidInputException>()),
      );
    });

    test('items in folders (index.md) are loaded and kept in place', () async {
      final (backlog, _) = await tempBacklog();
      final folder = Directory(p.join(backlog.root, 'items', 'T-abcd-with-attachments'))..createSync();
      File(p.join(folder.path, 'index.md')).writeAsStringSync('---\nid: T-abcd\ntitle: With attachments\n---\n');
      File(p.join(folder.path, 'screenshot.png')).writeAsBytesSync([0]);

      await backlog.items.update('abcd', [FieldChange.parse('status=todo')]);
      expect(File(p.join(folder.path, 'index.md')).readAsStringSync(), contains('status: todo'));
      expect(
        Directory(p.join(backlog.root, 'items')).listSync().whereType<File>().where((f) => f.path.endsWith('.md')),
        isEmpty,
      );
    });

    test('update replaces the body and keeps the front matter', () async {
      final (backlog, _) = await tempBacklog();
      await backlog.items.create(const NewItem(title: 'Body', labels: ['a'], body: 'Old text.\n'));
      final updated = await backlog.items.update('0001', [FieldChange.parse('priority=p0')], body: '- [x] new\n');
      expect(updated.checklist.done, 1);
      final file = File((await backlog.items.locate('0001'))!).readAsStringSync();
      expect(file, contains('labels: [a]'));
      expect(file, contains('priority: p0'));
      expect(file, endsWith('- [x] new\n'));
      expect(file, isNot(contains('Old text')));
    });
  });

  group('claims', () {
    Future<Backlog> withTasks(Backlog backlog, int count) async {
      for (var i = 0; i < count; i++) {
        await backlog.items.create(NewItem(title: 'Task $i', status: 'todo', priority: 'p${i % 4}'));
      }
      return backlog;
    }

    test('claim moves the item to in-progress and records the assignee', () async {
      final (backlog, _) = await tempBacklog();
      await withTasks(backlog, 1);
      final outcome = await backlog.claims.claim('0001', 'monorepo-2');
      expect(outcome.item.status, 'in-progress');
      expect(outcome.item.assignee, 'monorepo-2');
      expect((await backlog.items.get('0001')).assignee, 'monorepo-2');
      expect((await backlog.planning.snapshot()).ready, isEmpty);
    });

    test('a second agent is refused; the holder renews', () async {
      final (backlog, _) = await tempBacklog();
      await withTasks(backlog, 1);
      await backlog.claims.claim('0001', 'a');
      expect(() => backlog.claims.claim('0001', 'b'), throwsA(isA<ClaimConflictException>()));
      final again = await backlog.claims.claim('0001', 'a');
      expect(again.claim.agent, 'a');
    });

    test('an expired claim can be taken over', () async {
      final (backlog, clock) = await tempBacklog();
      await withTasks(backlog, 1);
      await backlog.claims.claim('0001', 'crashed-agent');
      clock.advance(const Duration(hours: 5));
      final outcome = await backlog.claims.claim('0001', 'b');
      expect(outcome.tookOver?.agent, 'crashed-agent');
      expect(outcome.item.assignee, 'b');
    });

    test('heartbeat keeps a claim alive', () async {
      final (backlog, clock) = await tempBacklog();
      await withTasks(backlog, 1);
      await backlog.claims.claim('0001', 'a');
      clock.advance(const Duration(hours: 3));
      await backlog.claims.heartbeat('0001', 'a');
      clock.advance(const Duration(hours: 3));
      expect(() => backlog.claims.claim('0001', 'b'), throwsA(isA<ClaimConflictException>()));
      expect(() => backlog.claims.heartbeat('0001', 'b'), throwsA(isA<ClaimConflictException>()));
    });

    test('blocked items and parents with open children need --force', () async {
      final (backlog, _) = await tempBacklog();
      final first = await backlog.items.create(const NewItem(title: 'First', status: 'todo'));
      await backlog.items.create(NewItem(title: 'Second', status: 'todo', dependsOn: [first.id.value]));
      final epic = await backlog.items.create(const NewItem(title: 'Epic', type: 'epic', status: 'todo'));
      await backlog.items.create(NewItem(title: 'Child', status: 'todo', parent: epic.id.value));

      expect(() => backlog.claims.claim('0002', 'a'), throwsA(isA<InvalidInputException>()));
      expect(() => backlog.claims.claim('0003', 'a'), throwsA(isA<InvalidInputException>()));
      expect((await backlog.claims.claim('0002', 'a', force: true)).item.status, 'in-progress');
    });

    test('release returns the item; complete finishes it and unblocks dependents', () async {
      final (backlog, _) = await tempBacklog();
      final first = await backlog.items.create(const NewItem(title: 'First', status: 'todo'));
      await backlog.items.create(NewItem(title: 'Second', status: 'todo', dependsOn: [first.id.value]));

      await backlog.claims.claim('0001', 'a');
      expect(() => backlog.claims.release('0001', agent: 'b'), throwsA(isA<ClaimConflictException>()));
      final released = await backlog.claims.release('0001', agent: 'a');
      expect(released.status, 'todo');
      expect(released.assignee, isNull);
      expect(await backlog.claims.all(), isEmpty);

      await backlog.claims.claim('0001', 'a');
      final done = await backlog.claims.complete('0001', agent: 'a');
      expect(done.status, 'done');
      expect(done.assignee, 'a');
      expect((await backlog.planning.snapshot()).ready.map((i) => i.id.value), ['T-0002']);
      expect(() => backlog.claims.complete('0002', status: 'todo'), throwsA(isA<InvalidInputException>()));
    });

    test('claimNext takes the most urgent ready item', () async {
      final (backlog, _) = await tempBacklog();
      await withTasks(backlog, 4); // priorities p0..p3
      final first = await backlog.claims.claimNext('a');
      final second = await backlog.claims.claimNext('b', where: (i) => i.item.priority != 'p1');
      expect(first!.item.priority, 'p0');
      expect(second!.item.priority, 'p2');
    });

    test('agents racing in parallel isolates never share an item', () async {
      final (backlog, _) = await tempBacklog();
      await withTasks(backlog, 5);
      final root = backlog.root;

      final results = await Future.wait([
        for (var agent = 0; agent < 12; agent++)
          Isolate.run(() async {
            final mine = await Backlog.open(root);
            final outcome = await mine.claims.claimNext('agent-$agent');
            return outcome?.item.id.value;
          }),
      ]);

      final claimed = results.whereType<String>().toList();
      expect(claimed, hasLength(5));
      expect(claimed.toSet(), hasLength(5));
      expect(await backlog.claims.all(), hasLength(5));
    });

    test('racing for one item: exactly one winner', () async {
      final (backlog, _) = await tempBacklog();
      await withTasks(backlog, 1);
      final root = backlog.root;

      final results = await Future.wait([
        for (var agent = 0; agent < 12; agent++)
          Isolate.run(() async {
            try {
              await (await Backlog.open(root)).claims.claim('T-0001', 'agent-$agent');
              return true;
            } on BacklogException {
              return false;
            }
          }),
      ]);
      expect(results.where((won) => won), hasLength(1));
    });
  });

  group('lint', () {
    test('a clean backlog has no issues', () async {
      final (backlog, _) = await tempBacklog();
      await backlog.items.create(const NewItem(title: 'Fine'));
      expect(await backlog.linter.run(), isEmpty);
    });

    test('reports broken files, duplicates, unknown values, dangling references and cycles', () async {
      final (backlog, _) = await tempBacklog();
      void write(String name, String content) => File(p.join(backlog.root, 'items', name)).writeAsStringSync(content);
      write('T-0001-a.md', '---\nid: T-0001\ntitle: A\ndepends_on: [T-0002]\n---\n');
      write('T-0002-b.md', '---\nid: T-0002\ntitle: B\ndepends_on: [T-0001]\nstatus: doing\n---\n');
      write('T-0002-copy.md', '---\nid: T-0002\ntitle: Copy\n---\n');
      write('T-0003-c.md', '---\nid: T-0003\ntitle: C\nrelated: [T-0404]\npriority: urgent\n---\n');
      write('broken.md', 'no front matter');
      write('renamed.md', '---\nid: T-0005\ntitle: E\n---\n');
      File(p.join(backlog.root, 'views', 'bad.yaml')).writeAsStringSync('layout: pie\n');

      final codes = (await backlog.linter.run()).map((i) => i.code).toList();
      expect(
        codes,
        containsAll([
          'unreadable',
          'duplicate-id',
          'unknown-status',
          'unknown-priority',
          'dangling-reference',
          'dependency-cycle',
          'file-name',
          'invalid-view',
        ]),
      );
    });

    test('reports leftover claims', () async {
      final (backlog, clock) = await tempBacklog();
      await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
      await backlog.items.create(const NewItem(title: 'B', status: 'todo'));
      await backlog.claims.claim('0001', 'a');
      await backlog.claims.claim('0002', 'a');
      await backlog.items.update('0002', [FieldChange.parse('status=done')]);
      clock.advance(const Duration(days: 1));
      final codes = (await backlog.linter.run()).map((i) => i.code);
      expect(codes, containsAll(['expired-claim', 'stale-claim']));
    });
  });

  group('views', () {
    test('sections are read from the YAML and set without touching the rest', () async {
      final (backlog, _) = await tempBacklog();
      final file = File(p.join(backlog.root, 'views', 'board.yaml'));
      file.writeAsStringSync('# my board\nname: Board # main one\nlayout: kanban\ngroup_by: status\n');

      var board = await backlog.views.setSection('board', 'Planning');
      expect(board.section, 'Planning');
      expect(file.readAsStringSync(), contains('# my board\nname: Board # main one\nlayout: kanban\n'));
      expect(file.readAsStringSync(), contains('section: Planning'));

      board = await backlog.views.setSection('board', ' ');
      expect(board.section, isNull);
      expect(file.readAsStringSync(), isNot(contains('section')));
      expect((await backlog.views.all()).where((v) => v.id == 'ready').single.section, isNull);
    });

    test('only existing views can get a section', () async {
      final (backlog, _) = await tempBacklog();
      expect(() => backlog.views.setSection('../backlog', 'X'), throwsA(isA<NotFoundException>()));
      expect(() => backlog.views.setSection('nope', 'X'), throwsA(isA<NotFoundException>()));
    });
  });
}
