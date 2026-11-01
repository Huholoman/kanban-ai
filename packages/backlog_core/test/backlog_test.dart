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
      await expectLater(() => Backlog.init(backlog.root), throwsA(isA<InvalidInputException>()));
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
      await expectLater(() => Backlog.open(dir.path), throwsA(isA<NotFoundException>()));
    });
  });

  group('storage', () {
    test('connect wires every service to the stores of the given storage', () async {
      final (opened, _) = await tempBacklog();
      final storage = _RecordingStorage(FileBacklogStorage(opened.root));
      final backlog = await Backlog.connect(storage, ids: SequentialIds());

      expect(backlog.root, opened.root);
      expect(storage.workflows.single.idPrefix, 'T');
      final created = await backlog.items.create(const NewItem(title: 'Through the port'));
      expect(storage.saved, [created.id]);
      expect(backlog.storage.displayLocation((await backlog.items.locate(created.id.value))!), startsWith('items/'));
      await backlog.actionRequests.add(
        ActionRequest(item: created.id.value, action: 'check', by: 'me', at: DateTime.utc(2026)),
      );
      expect((await FileBacklogStorage(opened.root).actionRequests.take()).single.action, 'check');
    });

    test('every connect gets fresh stores', () async {
      final (opened, _) = await tempBacklog();
      final storage = _RecordingStorage(FileBacklogStorage(opened.root));
      await Backlog.connect(storage);
      await Backlog.connect(storage);
      expect(storage.workflows, hasLength(2));
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
      expect(text, contains('created: 2026-10-29T12:00:00Z\n'));
      expect(text, contains('updated: 2026-10-29T12:00:00Z\n'));
      expect((await backlog.items.get('0002')).labels, ['infra']);
    });

    test('create validates against the workflow and resolves references', () async {
      final (backlog, _) = await tempBacklog();
      await expectLater(
        () => backlog.items.create(const NewItem(title: 'x', status: 'doing')),
        throwsA(isA<InvalidInputException>()),
      );
      await expectLater(
        () => backlog.items.create(const NewItem(title: 'x', dependsOn: ['nope'])),
        throwsA(isA<NotFoundException>()),
      );
      await expectLater(() => backlog.items.create(const NewItem(title: '  ')), throwsA(isA<InvalidInputException>()));
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
      expect(updated.updated, '2026-10-30T12:00:00Z');
      expect(File(path).readAsStringSync(), contains('Hand-written notes.'));
      expect(File(path).readAsStringSync(), contains('updated: 2026-10-30T12:00:00Z\n'));

      clock.advance(const Duration(minutes: 5));
      final before = File(path).readAsStringSync();
      final unchanged = await backlog.items.update('0002', [FieldChange.parse('labels=y')]);
      expect(unchanged.updated, '2026-10-30T12:00:00Z', reason: 'a change that changes nothing keeps updated');
      expect(File(path).readAsStringSync(), before);

      await expectLater(
        () => backlog.items.update('0002', [FieldChange.parse('depends_on+=0002')]),
        throwsA(isA<InvalidInputException>()),
      );
      await expectLater(
        () => backlog.items.update('0002', [FieldChange.parse('id=T-9')]),
        throwsA(isA<InvalidInputException>()),
      );
      await expectLater(
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
      await expectLater(() => backlog.claims.claim('0001', 'b'), throwsA(isA<ClaimConflictException>()));
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
      await expectLater(() => backlog.claims.claim('0001', 'b'), throwsA(isA<ClaimConflictException>()));
      await expectLater(() => backlog.claims.heartbeat('0001', 'b'), throwsA(isA<ClaimConflictException>()));
    });

    test('blocked items and parents with open children need --force', () async {
      final (backlog, _) = await tempBacklog();
      final first = await backlog.items.create(const NewItem(title: 'First', status: 'todo'));
      await backlog.items.create(NewItem(title: 'Second', status: 'todo', dependsOn: [first.id.value]));
      final epic = await backlog.items.create(const NewItem(title: 'Epic', type: 'epic', status: 'todo'));
      await backlog.items.create(NewItem(title: 'Child', status: 'todo', parent: epic.id.value));

      await expectLater(() => backlog.claims.claim('0002', 'a'), throwsA(isA<InvalidInputException>()));
      await expectLater(() => backlog.claims.claim('0003', 'a'), throwsA(isA<InvalidInputException>()));
      expect((await backlog.claims.claim('0002', 'a', force: true)).item.status, 'in-progress');
    });

    test('items waiting for overlapping work need --force; next skips them', () async {
      final (backlog, _) = await tempBacklog();
      await backlog.items.create(
        const NewItem(title: 'Payments', status: 'todo', priority: 'p1', touches: ['lib/pay/']),
      );
      await backlog.items.create(
        const NewItem(title: 'Stripe', status: 'todo', priority: 'p0', touches: ['lib/pay/stripe.dart']),
      );
      await backlog.items.create(
        const NewItem(title: 'Orders', status: 'todo', priority: 'p2', touches: ['lib/orders/']),
      );

      await backlog.claims.claim('0001', 'a');
      await expectLater(
        () => backlog.claims.claim('0002', 'b'),
        throwsA(isA<InvalidInputException>().having((e) => e.message, 'message', contains('T-0001'))),
      );
      expect((await backlog.claims.claimNext('b'))!.item.id.value, 'T-0003');

      await backlog.claims.complete('0001', agent: 'a');
      expect((await backlog.planning.snapshot()).ready.map((i) => i.id.value), ['T-0002']);
      await backlog.items.create(const NewItem(title: 'Order export', status: 'todo', touches: ['lib/orders/x.dart']));
      await expectLater(() => backlog.claims.claim('0004', 'c'), throwsA(isA<InvalidInputException>()));
      expect((await backlog.claims.claim('0004', 'c', force: true)).item.status, 'in-progress');
    });

    test('release returns the item; complete finishes it and unblocks dependents', () async {
      final (backlog, _) = await tempBacklog();
      final first = await backlog.items.create(const NewItem(title: 'First', status: 'todo'));
      await backlog.items.create(NewItem(title: 'Second', status: 'todo', dependsOn: [first.id.value]));

      await backlog.claims.claim('0001', 'a');
      await expectLater(() => backlog.claims.release('0001', agent: 'b'), throwsA(isA<ClaimConflictException>()));
      final released = await backlog.claims.release('0001', agent: 'a');
      expect(released.status, 'todo');
      expect(released.assignee, isNull);
      expect(await backlog.claims.all(), isEmpty);

      await backlog.claims.claim('0001', 'a');
      final done = await backlog.claims.complete('0001', agent: 'a');
      expect(done.status, 'done');
      expect(done.assignee, 'a');
      expect((await backlog.planning.snapshot()).ready.map((i) => i.id.value), ['T-0002']);
      await expectLater(() => backlog.claims.complete('0002', status: 'todo'), throwsA(isA<InvalidInputException>()));
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

    test('warns about malformed or overly broad touches', () async {
      final (backlog, _) = await tempBacklog();
      await backlog.items.create(const NewItem(title: 'A', touches: ['lib/[ab', '**', 'lib/a/']));
      final issues = (await backlog.linter.run()).where((i) => i.code == 'invalid-touches').toList();
      expect(issues.map((i) => i.message), [contains('lib/[ab'), contains('whole repository')]);
      expect(issues.every((i) => i.severity == Severity.warning), isTrue);
    });

    test('warns when two items in progress touch the same files', () async {
      final (backlog, _) = await tempBacklog();
      await backlog.items.create(const NewItem(title: 'A', status: 'in-progress', touches: ['lib/a/']));
      await backlog.items.create(const NewItem(title: 'B', status: 'review', touches: ['lib/a/b.dart']));
      await backlog.items.create(const NewItem(title: 'C', status: 'in-progress', touches: ['lib/c/']));
      final issues = (await backlog.linter.run()).where((i) => i.code == 'touches-overlap').toList();
      expect(issues, hasLength(1));
      expect('${issues.single.item} ${issues.single.message}', allOf(contains('T-0001'), contains('T-0002')));
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

    test('warns about dispatcher worktrees that are not folders', () async {
      final (backlog, _) = await tempBacklog(
        config: 'dispatcher: {command: sh, worktrees: [{name: here, path: .}, {name: gone, path: ../nowhere}]}\n',
      );
      final issues = await backlog.linter.run();
      expect(issues.map((i) => (i.severity, i.code)), [(Severity.warning, 'dispatcher-worktree')]);
      expect(issues.single.message, contains('"gone"'));
    });

    test('warns about a dispatcher repo that is not a folder', () async {
      final (backlog, _) = await tempBacklog(config: 'dispatcher: {command: sh, repo: ../nowhere, max_worktrees: 2}\n');
      final issues = await backlog.linter.run();
      expect(issues.map((i) => (i.severity, i.code)), [(Severity.warning, 'dispatcher-repo')]);
    });

    test('warns about a dispatcher agent that is not on the PATH or an unverified preset', () async {
      final (backlog, _) = await tempBacklog(
        config:
            'dispatcher: {agent: codex, agents: {codex: {command: no-such-agent-xyz}}, worktrees: [{name: here, path: .}]}\n',
      );
      final issues = await backlog.linter.run();
      expect(issues.map((i) => i.code), ['dispatcher-agent']);
      expect(issues.single.message, contains('"no-such-agent-xyz", which is not on the PATH'));

      final (preset, _) = await tempBacklog(
        config: 'dispatcher: {agent: gemini, worktrees: [{name: here, path: .}]}\n',
      );
      expect((await preset.linter.run()).map((i) => i.message), contains(contains('unverified preset')));
    });

    test('warns when dispatcher.allow cannot apply to an agent', () async {
      final (backlog, _) = await tempBacklog(
        config:
            'dispatcher: {command: sh, allow: ["Bash(dotnet *)"], worktrees: [{name: here, path: .}], '
            'actions: [{name: R, prompt: x, agent: claude}]}\n',
      );
      final issues = (await backlog.linter.run()).where((i) => i.code == 'dispatcher-allow');
      expect(issues.map((i) => i.message), [contains('agent "command"')]);
    });

    test('warns about actions whose program is not on the PATH or that can never run', () async {
      final (backlog, _) = await tempBacklog(
        config:
            'dispatcher: {command: sh, worktrees: [{name: here, path: .}], actions: ['
            '{name: Tests, run: [no-such-tool-xyz, check]}, {name: Never, statuses: [], run: noop}, '
            '{name: Review, prompt: x, agent: gemini}, {name: Fine, run: [sh, -c, "true"]}]}\n',
      );
      final issues = await backlog.linter.run();
      expect(issues.map((i) => i.code).toSet(), {'dispatcher-action'});
      expect(
        issues.map((i) => i.message),
        containsAll([
          'Action "Tests": it runs "no-such-tool-xyz", which is not on the PATH.',
          'Action "Never": it has no on_enter and an empty statuses list, so it can never run.',
          'Action "Review": its agent "gemini" is an unverified preset.',
        ]),
      );
      expect(issues.map((i) => i.message), isNot(contains(contains('"Fine"'))));
    });

    test('warns about a pull request command that is not on the PATH', () async {
      final (backlog, _) = await tempBacklog(
        config:
            'dispatcher: {command: sh, worktrees: [{name: here, path: .}], pr: {create: no-such-tea-xyz, find: sh, review: no-such-gh-xyz}}\n',
      );
      final issues = await backlog.linter.run();
      expect(issues.map((i) => i.code), ['dispatcher-pr', 'dispatcher-pr']);
      expect(issues.first.message, contains('"no-such-tea-xyz", which is not on the PATH'));
      expect(issues.first.message, contains('pull requests cannot be opened'));
      expect(issues.last.message, contains('"no-such-gh-xyz", which is not on the PATH; reviews are not posted'));
    });

    test('warns about merge commands that are not on the PATH', () async {
      final (backlog, _) = await tempBacklog(
        config:
            'dispatcher: {command: sh, worktrees: [{name: here, path: .}], '
            'pr: {create: sh, merge: no-such-merge-xyz, state: no-such-state-xyz}, '
            'merge: {strategy: local, check: no-such-check-xyz}}\n',
      );
      final issues = await backlog.linter.run();
      expect(issues.map((i) => i.code), unorderedEquals(['dispatcher-pr', 'dispatcher-pr', 'dispatcher-merge']));
      expect(
        issues.map((i) => i.message),
        containsAll([
          'dispatcher.pr runs "no-such-merge-xyz", which is not on the PATH.',
          'dispatcher.merge runs "no-such-check-xyz", which is not on the PATH.',
        ]),
      );
    });
  });

  group('views', () {
    test('counts gives every view with the number of items it shows', () async {
      final (backlog, _) = await tempBacklog();
      await backlog.items.create(const NewItem(title: 'Open', status: 'todo'));
      await backlog.items.create(const NewItem(title: 'Finished', status: 'done'));
      final counts = await backlog.views.counts();
      expect(counts.map((entry) => entry.$1.id), (await backlog.views.all()).map((view) => view.id));
      for (final (view, count) in counts) {
        expect(count, (await backlog.views.evaluate(view)).items.toSet().length, reason: view.id);
      }
    });

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

    test('columns are set as a flow list and removed again', () async {
      final (backlog, _) = await tempBacklog();
      final file = File(p.join(backlog.root, 'views', 'board.yaml'));
      final before = file.readAsStringSync();

      final board = await backlog.views.setColumns('board', ['review', 'todo', ' ']);
      expect(board.columns, ['review', 'todo']);
      expect(file.readAsStringSync(), contains('columns: [review, todo]'));
      expect((await backlog.views.run('board')).groups.map((g) => g.key), ['review', 'todo']);

      expect((await backlog.views.setColumns('board', null)).columns, isNull);
      expect(file.readAsStringSync(), isNot(contains('columns:')));
      expect(file.readAsStringSync().replaceAll(RegExp(r'\s'), ''), isNot(isEmpty));
      expect(before, contains('name: Board'));
      await expectLater(
        () => backlog.views.setColumns('board', ['todo', 'todo']),
        throwsA(isA<InvalidInputException>()),
      );
    });

    test('a filter is saved as a new view derived from another', () async {
      final (backlog, _) = await tempBacklog();
      final epic = await backlog.items.create(const NewItem(title: 'Payments', type: 'epic', status: 'todo'));
      final story = await backlog.items.create(
        NewItem(title: 'Deposit "quoted" #1', status: 'todo', parent: epic.id.value, labels: const ['web']),
      );
      await backlog.items.create(const NewItem(title: 'Other', status: 'todo', labels: ['web']));

      final view = await backlog.views.saveAs(
        name: 'Web payments',
        section: 'Mine',
        base: 'board',
        conditions: [
          {
            'labels': ['web'],
          },
          {
            'epic': [epic.id.value],
          },
          {
            'or': [
              {
                'title': {'contains': 'deposit "q'},
              },
              {
                'id': {'contains': 'zzz'},
              },
            ],
          },
        ],
      );
      expect(view.id, 'web-payments');
      expect(view.section, 'Mine');
      expect(view.layout, ViewLayout.kanban);
      expect(view.groupBy, 'status');
      final result = await backlog.views.run(view.id);
      expect(result.items.map((i) => i.id), [story.id]);
      expect(result.groups.map((g) => g.key), contains('todo'), reason: 'columns copied from the board');

      final again = await backlog.views.saveAs(name: 'Web payments');
      expect(again.id, 'web-payments-2');
      expect(again.layout, ViewLayout.list);
      await expectLater(() => backlog.views.saveAs(name: ' '), throwsA(isA<InvalidInputException>()));
      expect(
        () => backlog.views.saveAs(
          name: 'Bad',
          conditions: [
            {
              'status': {'between': 1},
            },
          ],
        ),
        throwsA(isA<InvalidInputException>()),
      );
    });

    test('only existing views can get a section', () async {
      final (backlog, _) = await tempBacklog();
      await expectLater(() => backlog.views.setSection('../backlog', 'X'), throwsA(isA<NotFoundException>()));
      await expectLater(() => backlog.views.setSection('nope', 'X'), throwsA(isA<NotFoundException>()));
    });
  });

  test('touches is a list field: created, added to, removed from', () async {
    final (backlog, _) = await tempBacklog();
    final created = await backlog.items.create(const NewItem(title: 'Payments', touches: ['lib/payments/']));
    expect(created.touches, ['lib/payments/']);
    await backlog.items.update('0001', [FieldChange.parse('touches+=lib/*.{dart,yaml},docs/')]);
    expect((await backlog.items.get('0001')).touches, ['lib/payments/', 'lib/*.{dart,yaml}', 'docs/']);
    final removed = await backlog.items.update('0001', [FieldChange.parse('touches-=lib/payments/')]);
    expect(removed.touches, ['lib/*.{dart,yaml}', 'docs/']);
    expect(removed.extra, isEmpty);
  });

  test('pr is a regular field: set, saved and cleared', () async {
    final (backlog, _) = await tempBacklog();
    final created = await backlog.items.create(const NewItem(title: 'Ship it', pr: 'https://github.com/o/r/pull/1'));
    expect(created.pr, 'https://github.com/o/r/pull/1');
    final updated = await backlog.items.update(created.id.value, [
      FieldChange.parse('pr=https://github.com/o/r/pull/2'),
    ]);
    expect((await backlog.items.get(updated.id.value)).pr, 'https://github.com/o/r/pull/2');
    final cleared = await backlog.items.update(created.id.value, [FieldChange.parse('pr=')]);
    expect(cleared.pr, isNull);
    expect(cleared.extra, isEmpty);
  });

  test('rank is a number field: set, saved and cleared', () async {
    final (backlog, _) = await tempBacklog();
    final created = await backlog.items.create(const NewItem(title: 'First'));
    await backlog.items.update(created.id.value, [FieldChange.parse('rank=1024')]);
    expect((await backlog.items.get(created.id.value)).rank, 1024);
    await expectLater(
      () => backlog.items.update(created.id.value, [FieldChange.parse('rank=top')]),
      throwsA(isA<InvalidInputException>()),
    );
    final cleared = await backlog.items.update(created.id.value, [FieldChange.parse('rank=')]);
    expect(cleared.rank, isNull);
    expect(cleared.extra, isEmpty);
  });
}

/// A storage that records which stores the backlog asked for and which items
/// it saved, delegating to [_inner].
final class _RecordingStorage implements BacklogStorage {
  _RecordingStorage(this._inner);

  final BacklogStorage _inner;
  final workflows = <Workflow>[];
  final saved = <ItemId>[];

  @override
  String get root => _inner.root;

  @override
  Future<bool> exists() => _inner.exists();

  @override
  ChangeSource watch({Duration debounce = const Duration(milliseconds: 150)}) => _inner.watch(debounce: debounce);

  @override
  WorkflowSource get configuration => _inner.configuration;

  @override
  ActionRequests get actionRequests => _inner.actionRequests;

  @override
  BacklogStores stores(Workflow workflow) {
    workflows.add(workflow);
    final inner = _inner.stores(workflow);
    return BacklogStores(
      items: _RecordingItems(inner.items, saved),
      claims: inner.claims,
      views: inner.views,
      revisions: inner.revisions,
      decode: inner.decode,
    );
  }

  @override
  String displayLocation(String location) => _inner.displayLocation(location);
}

final class _RecordingItems implements ItemRepository {
  _RecordingItems(this._inner, this._saved);

  final ItemRepository _inner;
  final List<ItemId> _saved;

  @override
  Future<ItemCatalog> load() => _inner.load();

  @override
  Future<void> save(Item item) async {
    _saved.add(item.id);
    await _inner.save(item);
  }

  @override
  Future<String?> locationOf(ItemId id) => _inner.locationOf(id);
}
