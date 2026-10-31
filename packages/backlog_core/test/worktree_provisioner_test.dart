@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Future<String> _git(String dir, List<String> arguments) async {
  final result = await Process.run('git', arguments, workingDirectory: dir);
  if (result.exitCode != 0) throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
  return '${result.stdout}'.trim();
}

void main() {
  late Directory root;
  late Backlog backlog;
  late FixedClock clock;
  late ProcessAgentLauncher agents;
  late WorktreeProvisioner launcher;
  late List<String> logs;

  String path(String name) => p.join(root.path, name);
  String stateDir() => path('state');

  Future<void> configure(String extra) => File(p.join(path('backlog'), 'backlog.yaml')).writeAsString('''
dispatcher:
  mode: manual
  repo: ../repo
  base: main
  agent: quick
  agents:
    quick:
      command: [sh, -c, "echo working on {id} in {worktree}"]
$extra''');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('worktree_provisioner_');
    addTearDown(() => root.delete(recursive: true));
    final repo = path('repo');
    await Directory(repo).create();
    await _git(repo, ['init', '-q', '-b', 'main']);
    await _git(repo, ['config', 'user.email', 'test@example.com']);
    await _git(repo, ['config', 'user.name', 'Test']);
    File(p.join(repo, 'README.md')).writeAsStringSync('# Demo\n');
    await _git(repo, ['add', '.']);
    await _git(repo, ['commit', '-q', '-m', 'Initial commit']);
    // A folder with a fitting name that the dispatcher did not create: never used.
    await Directory(path('repo-2')).create();

    await Backlog.init(path('backlog'));
    await configure('  max_worktrees: 2\n');
    clock = FixedClock(DateTime.utc(2026, 10, 31, 12));
    backlog = await Backlog.open(path('backlog'), clock: clock, ids: SequentialIds());
    logs = [];
    agents = ProcessAgentLauncher(
      project: 'demo',
      backlog: () async => backlog,
      stateDir: stateDir(),
      clock: clock,
      log: logs.add,
      environment: {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin', 'HOME': root.path},
    );
    launcher = WorktreeProvisioner(agents, project: 'demo', stateDir: stateDir(), clock: clock, log: logs.add);
    addTearDown(launcher.close);
  });

  Future<DispatchPlan> plan() async {
    final snapshot = await backlog.planning.snapshot();
    return DispatchPlan.of(
      snapshot,
      backlogRoot: backlog.root,
      conditions: await launcher.conditions(snapshot.workflow.dispatcher!, backlog.root, snapshot),
    )!;
  }

  /// Waits until the agent of [id] ended and the launcher dealt with it.
  Future<void> ended(String id) async {
    for (var i = 0; i < 100; i++) {
      await agents.tick();
      if (!File(p.join(stateDir(), 'agents', 'demo', '$id.json')).existsSync()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('the agent for $id did not end');
  }

  test('creates the next free worktrees next to the repo, up to max_worktrees, and reuses them', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo', priority: 'p1'));
    await backlog.items.create(const NewItem(title: 'B', status: 'todo'));
    await backlog.items.create(const NewItem(title: 'C', status: 'todo'));

    final first = await plan();
    expect(first.assignments.map((a) => '${a.id}@${a.agent}'), ['T-0001@repo-3', 'T-0002@repo-4']);
    expect(first.assignments.map((a) => a.createFrom), everyElement(path('repo')));
    expect(first.worktrees.map((w) => (w.name, w.isNew)), [('repo-3', true), ('repo-4', true)]);
    expect(first.waiting.map((i) => '${i.id}'), ['T-0003']);

    await launcher.launch(first.assignmentFor('T-0001'));
    expect(await _git(path('repo-3'), ['symbolic-ref', '--short', 'HEAD']), 'agent/T-0001');
    expect(await _git(path('repo'), ['worktree', 'list']), contains(path('repo-3')));
    expect(logs, contains(contains('created worktree repo-3')));
    final record = jsonDecode(File(p.join(stateDir(), 'worktrees', 'demo', 'repo-3.json')).readAsStringSync()) as Map;
    expect(record, containsPair('repo', path('repo')));

    final busy = await plan();
    expect(busy.worktrees.map((w) => (w.name, w.created, w.isBusy, w.isNew)), [
      ('repo-3', true, true, false),
      ('repo-4', true, false, true),
    ]);
    expect(busy.assignments.single.agent, 'repo-4');

    // The agent hands over; the created worktree is free again and used first.
    await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
    await ended('T-0001');
    final again = await plan();
    expect(again.assignments.map((a) => '${a.id}@${a.agent}@${a.createFrom != null}'), [
      'T-0002@repo-3@false',
      'T-0003@repo-4@true',
    ]);

    // Without max_worktrees room nothing new is proposed.
    await configure('  max_worktrees: 1\n');
    backlog = await Backlog.open(path('backlog'), clock: clock, ids: SequentialIds());
    final full = await plan();
    expect(full.spare, isEmpty);
    expect(full.assignments.map((a) => a.agent), ['repo-3']);
  });

  test('forgets a created worktree whose folder was removed', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    await launcher.launch((await plan()).assignmentFor('T-0001'));
    await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
    await ended('T-0001');
    await _git(path('repo'), ['worktree', 'remove', path('repo-3')]);

    await backlog.items.create(const NewItem(title: 'B', status: 'todo'));
    final next = await plan();
    expect(next.worktrees.where((w) => !w.isNew), isEmpty);
    expect(next.assignments.single.agent, 'repo-3', reason: 'the first free number again');
    expect(next.assignments.single.createFrom, isNotNull);
  });

  test('cleans up idle created worktrees only when nothing is lost', () async {
    await configure('  max_worktrees: 2\n  cleanup_after_days: 3\n');
    backlog = await Backlog.open(path('backlog'), clock: clock, ids: SequentialIds());
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    await backlog.items.create(const NewItem(title: 'B', status: 'todo'));
    await launcher.launch((await plan()).assignmentFor('T-0001'));
    await launcher.launch((await plan()).assignmentFor('T-0002'));
    for (final id in ['T-0001', 'T-0002']) {
      await backlog.items.update(id, [FieldChange.parse('status=review')]);
      await ended(id);
    }
    // repo-4 got a commit of its own that main does not have.
    File(path('repo-4/NOTES.md')).writeAsStringSync('notes\n');
    await _git(path('repo-4'), ['add', '.']);
    await _git(path('repo-4'), ['commit', '-q', '-m', 'Notes (T-0002)']);

    clock.advance(const Duration(days: 2));
    await plan();
    expect(Directory(path('repo-3')).existsSync(), isTrue, reason: 'not idle long enough');

    clock.advance(const Duration(days: 2));
    final later = await plan();
    expect(Directory(path('repo-3')).existsSync(), isFalse, reason: 'clean and nothing beyond main');
    expect(logs, contains(contains('removed idle worktree repo-3')));
    expect(Directory(path('repo-4')).existsSync(), isTrue, reason: 'its commit is not merged');
    expect(await _git(path('repo'), ['branch', '--list', 'agent/T-0001']), contains('agent/T-0001'));
    expect(later.worktrees.where((w) => !w.isNew).map((w) => w.name), ['repo-4']);

    // Once merged, it goes too.
    await _git(path('repo'), ['merge', '-q', '--ff-only', 'agent/T-0002']);
    await plan();
    expect(Directory(path('repo-4')).existsSync(), isFalse);
  });
}
