import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Future<void> _git(String folder, List<String> args, {DateTime? at}) async {
  final date = at?.toUtc().toIso8601String();
  final result = await Process.run(
    'git',
    args,
    workingDirectory: folder,
    environment: {'GIT_AUTHOR_DATE': ?date, 'GIT_COMMITTER_DATE': ?date},
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

/// Commits everything as [author], a minute after [clock]'s time.
Future<void> _commit(String folder, String author, FixedClock clock) async {
  await _git(folder, ['add', '-A']);
  await _git(folder, [
    '-c',
    'user.name=$author',
    '-c',
    'user.email=$author@example.com',
    'commit',
    '-q',
    '-m',
    'x',
  ], at: clock.now().add(const Duration(minutes: 1)));
}

void main() {
  group('ItemHistory', () {
    Item version(String status, {List<String> labels = const [], String body = '', String updated = ''}) => Item(
      id: ItemId('T-1'),
      title: 'Backups',
      type: 'task',
      status: status,
      priority: 'p2',
      labels: labels,
      created: '2026-10-29T08:00:00Z',
      updated: updated.isEmpty ? null : updated,
      body: body,
    );

    test('creation, field changes, checklist, description, comments and runs, oldest first', () {
      final first = version('todo', body: '- [ ] a\n- [ ] b\n');
      final second = version(
        'in-progress',
        labels: ['infra'],
        body: '- [x] a\n- [ ] b\n',
        updated: '2026-10-30T09:30:00Z',
      );
      final current = version(
        'review',
        labels: ['infra'],
        body:
            'More context.\n\n- [x] a\n- [ ] b\n\n## Discussion\n\n### m2 · 2026-10-30 11:00:00 UTC · question\n\nCSV?\n',
      );
      final entries = ItemHistory.build(
        current: current,
        revisions: [
          ItemRevision(item: first, at: DateTime.utc(2026, 10, 29, 9), commit: 'aaa', author: 'tobik'),
          ItemRevision(item: second, at: DateTime.utc(2026, 10, 30, 10), commit: 'bbb', author: 'tobik'),
        ],
        runs: [
          RunRecord(
            startedAt: DateTime.utc(2026, 10, 30, 9),
            log: '/logs/T-1.log',
            agent: 'claude',
            worktree: 'wt-1',
            ended: 'the agent exited with code 0',
          ),
        ],
        now: DateTime.utc(2026, 10, 31),
      );
      expect(entries.map((e) => '$e'), [
        '2026-10-29T08:00:00Z created: - → todo by tobik',
        '2026-10-30T09:00:00Z run by wt-1',
        '2026-10-30T09:30:00Z field status: todo → in-progress by tobik',
        '2026-10-30T09:30:00Z field labels: - → infra by tobik',
        '2026-10-30T09:30:00Z field checklist: 0/2 → 1/2 by tobik',
        '2026-10-30T11:00:00Z comment by m2',
        '2026-10-31T00:00:00Z field status: in-progress → review',
        '2026-10-31T00:00:00Z body',
      ]);
      expect(entries.first.commit, 'aaa');
      expect(entries.last.uncommitted, isTrue, reason: 'the file differs from the last commit');
      expect(entries.firstWhere((e) => e.kind == HistoryKind.comment).tag, 'question');
      expect(entries.firstWhere((e) => e.kind == HistoryKind.run).text, 'the agent exited with code 0');
      expect(ItemHistory.filter(entries, 'status').map((e) => e.kind), [
        HistoryKind.created,
        HistoryKind.field,
        HistoryKind.field,
      ]);
      expect(ItemHistory.filter(entries, 'runs').single.log, '/logs/T-1.log');
      expect(ItemHistory.filter(entries, 'comments').single.author, 'm2');
    });

    test('without revisions the item is its only version', () {
      final entries = ItemHistory.build(current: version('todo'));
      expect(entries.single.kind, HistoryKind.created);
      expect(entries.single.at, DateTime.utc(2026, 10, 29, 8));
      expect(entries.single.uncommitted, isTrue);
    });
  });

  test('HistoryService reads the committed versions of the file, across a rename', () async {
    final (backlog, clock) = await tempBacklog();
    final root = backlog.layout.root;
    await _git(root, ['init', '-q']);
    final item = await backlog.items.create(const NewItem(title: 'Backups', status: 'todo'));
    await _commit(root, 'tobik', clock);
    clock.advance(const Duration(hours: 1));
    await backlog.items.update(item.id.value, [FieldChange.parse('status=in-progress')]);
    await _commit(root, 'monorepo-2', clock);
    clock.advance(const Duration(hours: 1));
    await backlog.items.update(item.id.value, [FieldChange.parse('title=Nightly backups')]);
    await _commit(root, 'tobik', clock);
    clock.advance(const Duration(hours: 1));
    await backlog.items.update(item.id.value, [FieldChange.parse('priority=p0')]);

    final entries = await backlog.history.of(item.id.value);
    expect(entries.map((e) => (e.kind, e.field, e.after, e.author, e.uncommitted)), [
      (HistoryKind.created, null, 'todo', 'tobik', false),
      (HistoryKind.field, 'status', 'in-progress', 'monorepo-2', false),
      (HistoryKind.field, 'title', 'Nightly backups', 'tobik', false),
      (HistoryKind.field, 'priority', 'p0', null, true),
    ]);
    expect(entries[1].at, DateTime.utc(2026, 10, 29, 13), reason: 'when it was updated, not committed');
    expect(entries.last.at, DateTime.utc(2026, 10, 29, 15));
    expect(await backlog.history.of(item.id.value, only: 'status'), hasLength(2));
    await expectLater(backlog.history.of(item.id.value, only: 'nope'), throwsA(isA<InvalidInputException>()));
  });

  test('the history of an archived item includes its versions in items/', () async {
    final (backlog, clock) = await tempBacklog();
    final root = backlog.layout.root;
    await _git(root, ['init', '-q']);
    final item = await backlog.items.create(const NewItem(title: 'Backups', status: 'todo'));
    await _commit(root, 'tobik', clock);
    clock.advance(const Duration(hours: 1));
    await backlog.items.update(item.id.value, [FieldChange.parse('status=done')]);
    await _commit(root, 'monorepo-2', clock);
    await backlog.items.archive(references: [item.id.value]);
    await _commit(root, 'tobik', clock);

    final entries = await backlog.history.of(item.id.value);
    expect(entries.map((e) => (e.kind, e.field, e.after, e.uncommitted)), [
      (HistoryKind.created, null, 'todo', false),
      (HistoryKind.field, 'status', 'done', false),
    ]);
  });

  test('outside a git repository the history is the item and its discussion', () async {
    final (backlog, _) = await tempBacklog();
    final item = await backlog.items.create(const NewItem(title: 'Backups'));
    await backlog.items.comment(item.id.value, author: 'tobik', text: 'Hello');
    final entries = await backlog.history.of(item.id.value);
    expect(entries.map((e) => e.kind), [HistoryKind.created, HistoryKind.comment]);
  });

  test('ProcessAgentLauncher.runsOf reads the runs of an item from its logs', () async {
    final state = await Directory.systemTemp.createTemp('history_state_');
    addTearDown(() => state.delete(recursive: true));
    final (backlog, clock) = await tempBacklog();
    final launcher = ProcessAgentLauncher(
      project: 'demo',
      backlog: () async => backlog,
      stateDir: state.path,
      clock: clock,
    );
    final logs = await Directory(launcher.logsDir).create(recursive: true);
    File(p.join(logs.path, 'T-1-20261030T090000Z.log')).writeAsStringSync(
      '# kanban-ai: claude for T-1 in wt-1 (/w/wt-1), branch agent/T-1, started 2026-10-30T09:00:00.000Z\n'
      '# command: claude -p …\n'
      'work\n'
      '# kanban-ai: the agent exited with code 0; T-1 stays review\n',
    );
    File(p.join(logs.path, 'T-1-20261030T100000Z.log')).writeAsStringSync(
      '# kanban-ai: action "merge" (request) for T-1 in wt-2 (/w/wt-2), started 2026-10-30T10:00:00.000Z\n',
    );
    File(p.join(logs.path, 'T-1-20261030T110000Z.log')).writeAsStringSync(
      '# kanban-ai: claude for T-1 (action "AI review", on_enter) in wt-3 (/w/wt-3), branch -, started …\n',
    );
    File(p.join(logs.path, 'T-10-20261030T100000Z.log')).writeAsStringSync('# kanban-ai: other item\n');

    final runs = await launcher.runsOf(ItemId('T-1'));
    expect(runs.map((r) => (r.startedAt, r.agent, r.action, r.worktree, r.ended)), [
      (DateTime.utc(2026, 10, 30, 9), 'claude', null, 'wt-1', 'the agent exited with code 0; T-1 stays review'),
      (DateTime.utc(2026, 10, 30, 10), null, 'merge', 'wt-2', null),
      (DateTime.utc(2026, 10, 30, 11), 'claude', 'AI review', 'wt-3', null),
    ]);
  });
}
