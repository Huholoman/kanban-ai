@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// A fake agent: prints what it got, starts a child (to check that stopping
/// kills the whole group), then waits for `<worktree>/../go-<id>` and exits
/// with the code written there.
const _agentScript = r'''
id=$1
echo "agent $BACKLOG_AGENT on $id in $(pwd) branch $(git symbolic-ref --short HEAD) backlog $BACKLOG_DIR extra $EXTRA"
sleep 30 &
echo "child $!" > "../child-$id"
while [ ! -f "../go-$id" ]; do sleep 0.05; done
code=$(cat "../go-$id")
echo "done with $code"
kill %1 2>/dev/null
exit "$code"
''';

Future<String> _git(String dir, List<String> arguments) async {
  final result = await Process.run('git', arguments, workingDirectory: dir);
  if (result.exitCode != 0) throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
  return '${result.stdout}'.trim();
}

void main() {
  late Directory root;
  late Backlog backlog;
  late FixedClock clock;
  late ProcessAgentLauncher launcher;
  late List<String> logs;
  late String stateDir;

  String path(String name) => p.join(root.path, name);

  ProcessAgentLauncher newLauncher() => ProcessAgentLauncher(
    project: 'demo',
    backlog: () async => backlog,
    stateDir: stateDir,
    clock: clock,
    log: logs.add,
    heartbeatEvery: const Duration(minutes: 5),
    environment: {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin', 'HOME': root.path},
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent_launcher_');
    addTearDown(() async {
      // Leave no fake agent behind, whatever the test did.
      for (final file in root.listSync().whereType<File>().where((f) => p.basename(f.path).startsWith('child-'))) {
        final pid = int.tryParse(file.readAsStringSync().split(' ').last.trim());
        if (pid != null) Process.killPid(pid, ProcessSignal.sigkill);
      }
      for (final id in ['T-0001', 'T-0002']) {
        File(path('go-$id')).writeAsStringSync('1');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await root.delete(recursive: true);
    });
    final repo = path('repo');
    await Directory(repo).create();
    await _git(repo, ['init', '-q', '-b', 'main']);
    await _git(repo, ['config', 'user.email', 'test@example.com']);
    await _git(repo, ['config', 'user.name', 'Test']);
    File(p.join(repo, 'README.md')).writeAsStringSync('# Demo\n');
    await _git(repo, ['add', '.']);
    await _git(repo, ['commit', '-q', '-m', 'Initial commit']);
    for (final worktree in ['wt-1', 'wt-2']) {
      await _git(repo, ['worktree', 'add', '-q', '--detach', path(worktree)]);
    }
    File(path('agent.sh')).writeAsStringSync(_agentScript);

    await Backlog.init(path('backlog'));
    File(p.join(path('backlog'), 'backlog.yaml')).writeAsStringSync('''
dispatcher:
  mode: manual
  worktrees: [wt-1, wt-2]
  agent: fake
  agents:
    fake:
      command: [sh, ${path('agent.sh')}, "{id}"]
      env: {EXTRA: "{worktree}/{branch}"}
''');
    clock = FixedClock(DateTime.utc(2026, 10, 31, 12));
    backlog = await Backlog.open(path('backlog'), clock: clock, ids: SequentialIds());
    stateDir = path('state');
    logs = [];
    launcher = newLauncher();
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

  Future<PlannedItem> planned(String id) async => (await backlog.planning.snapshot())[ItemId(id)]!;

  /// Lets the fake agent of [id] finish with [code] and waits until the
  /// launcher has dealt with its end.
  Future<void> finish(String id, int code, {ProcessAgentLauncher? by}) async {
    File(path('go-$id')).writeAsStringSync('$code');
    final agents = by ?? launcher;
    for (var i = 0; i < 100; i++) {
      await agents.tick();
      if (!File(p.join(stateDir, 'agents', 'demo', '$id.json')).existsSync()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('the agent for $id did not end');
  }

  Future<String> logOf(String id) async => (await launcher.agentLog(ItemId(id)))!.lines.join('\n');

  Future<void> waitForLog(String id, String text) async {
    for (var i = 0; i < 100; i++) {
      if ((await launcher.agentLog(ItemId(id)))?.lines.any((l) => l.contains(text)) ?? false) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('"$text" never appeared in the log of $id:\n${await logOf(id)}');
  }

  test('starts a detached agent on its own branch and lets it hand over for review', () async {
    await backlog.items.create(const NewItem(title: 'Usage section', status: 'todo'));
    final assignment = (await plan()).assignmentFor('T-0001');
    await launcher.launch(assignment);

    final item = await planned('T-0001');
    expect(item.claim!.agent, 'wt-1');
    expect(item.item.status, 'in-progress');
    expect(item.item.branch, 'agent/T-0001');
    final record =
        jsonDecode(File(p.join(stateDir, 'agents', 'demo', 'T-0001.json')).readAsStringSync()) as Map<String, Object?>;
    expect(record, containsPair('worktree', 'wt-1'));
    expect(record['pid'], isA<int>());
    expect(p.dirname(record['log']! as String), p.join(stateDir, 'logs', 'demo'));
    await waitForLog('T-0001', 'agent wt-1');
    expect(
      await logOf('T-0001'),
      contains(
        'agent wt-1 on T-0001 in ${path('wt-1')} branch agent/T-0001 backlog ${backlog.root} extra wt-1/agent/T-0001',
      ),
    );

    final source = (await launcher.agentLogSource(ItemId('T-0001')))!;
    expect((source.path, source.running, source.output), (record['log'], true, AgentOutput.text));

    final busy = await plan();
    expect(busy.worktrees.first.run!.item, ItemId('T-0001'));
    expect(busy.worktrees.first.isBusy, isTrue);

    // The agent commits and asks for review, then exits.
    File(path('wt-1/USAGE.md')).writeAsStringSync('Run it.\n');
    await _git(path('wt-1'), ['add', '.']);
    await _git(path('wt-1'), ['-c', 'user.email=a@b', '-c', 'user.name=A', 'commit', '-q', '-m', 'Usage (T-0001)']);
    await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
    await finish('T-0001', 0);

    final after = await planned('T-0001');
    expect(after.item.status, 'review');
    expect(after.claim, isNull);
    expect(after.item.assignee, 'wt-1', reason: 'the assignee stays as a record');
    expect(await logOf('T-0001'), contains('exited with code 0'));
    expect(logs.last, contains('handed over as review'));
    final last = (await launcher.agentLog(ItemId('T-0001')))!;
    expect(last.running, isFalse);
    expect(last.last, containsPair('exit_code', 0));
    final ended = (await launcher.agentLogSource(ItemId('T-0001')))!;
    expect((ended.path, ended.running, ended.last?['exit_code']), (record['log'], false, 0));
    expect(await launcher.agentLogSource(ItemId('T-0009')), isNull);
    expect((await plan()).worktrees.first.isFree, isTrue, reason: 'committed work leaves the worktree clean');
  });

  test('an agent that ends without finishing releases and holds its item', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    await launcher.launch((await plan()).assignmentFor('T-0001'));
    await finish('T-0001', 3);

    final item = await planned('T-0001');
    expect(item.item.status, 'todo');
    expect(item.claim, isNull);
    final again = await plan();
    expect(again.assignments, isEmpty, reason: 'held items are not started by themselves');
    expect(again.held.single.reason, contains('exited with code 3'));
    expect(logs.last, contains('released and held'));

    // A person starts it again: that lifts the hold.
    await launcher.launch(again.assignmentFor('T-0001'));
    expect((await plan()).held, isEmpty);
    await finish('T-0001', 0);
  });

  test('worktrees with uncommitted changes or without git are not free', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    File(path('wt-1/scratch.txt')).writeAsStringSync('x');
    File(path('wt-2/.git')).deleteSync();

    final current = await plan();
    expect(current.worktrees.map((w) => w.unavailable), [
      'uncommitted changes (1 paths)',
      startsWith('not a git worktree'),
    ]);
    expect(current.assignments, isEmpty);
    expect(current.waiting.map((i) => '${i.id}'), ['T-0001']);
    expect(() => current.assignmentFor('T-0001'), throwsA(isA<UnavailableException>()));

    final forced = DispatchAssignment.render(
      backlog.workflow.dispatcher!,
      item: await planned('T-0001'),
      worktree: backlog.workflow.dispatcher!.worktrees.first,
      path: path('wt-1'),
      backlogRoot: backlog.root,
    );
    await expectLater(launcher.launch(forced), throwsA(isA<UnavailableException>()));
    expect((await planned('T-0001')).claim, isNull, reason: 'nothing is claimed for a dirty worktree');
  });

  test('someone faster wins the claim and nothing starts', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    final assignment = (await plan()).assignmentFor('T-0001');
    await backlog.claims.claim('T-0001', 'someone');
    await expectLater(launcher.launch(assignment), throwsA(isA<ClaimConflictException>()));
    expect(Directory(p.join(stateDir, 'agents', 'demo')).existsSync(), isFalse);
  });

  test('stop kills the agent with its children, releases and holds the item', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    await launcher.launch((await plan()).assignmentFor('T-0001'));
    await waitForLog('T-0001', 'agent wt-1');
    for (var i = 0; i < 100 && !File(path('child-T-0001')).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final child = int.parse(File(path('child-T-0001')).readAsStringSync().split(' ').last.trim());

    expect(await launcher.stop(ItemId('T-0001')), isTrue);
    expect(Directory('/proc/$child').existsSync(), isFalse, reason: 'the whole process group is stopped');
    final item = await planned('T-0001');
    expect(item.item.status, 'todo');
    expect((await plan()).held.single.reason, contains('stopped by a person'));
    expect(await launcher.stop(ItemId('T-0001')), isFalse);
  }, testOn: 'linux');

  test('a restarted server finds the running agent, keeps its claim alive and finishes it', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    await launcher.launch((await plan()).assignmentFor('T-0001'));
    await launcher.close();

    final restarted = newLauncher();
    addTearDown(restarted.close);
    final snapshot = await backlog.planning.snapshot();
    final conditions = await restarted.conditions(snapshot.workflow.dispatcher!, backlog.root, snapshot);
    expect(conditions.runs.single.worktree, 'wt-1');

    clock.advance(const Duration(hours: 1));
    await restarted.tick();
    expect((await planned('T-0001')).claim!.heartbeatAt, clock.now(), reason: 'heartbeat after re-attaching');

    await finish('T-0001', 0, by: restarted);
    expect((await planned('T-0001')).item.status, 'todo');
  });

  test('the dispatcher starts an item by hand in manual mode', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    await backlog.items.create(const NewItem(title: 'B', status: 'todo', priority: 'p0'));
    final dispatcher = Dispatcher(
      snapshot: backlog.planning.snapshot,
      backlogRoot: backlog.root,
      launcher: launcher,
      clock: clock,
      timer: (_, _) => _NoTimer(),
    );
    addTearDown(dispatcher.close);
    expect((await dispatcher.evaluate())!.assignments.map((a) => a.key), ['T-0002@wt-1', 'T-0001@wt-2']);

    final started = await dispatcher.start('T-0001');
    expect(started.key, 'T-0001@wt-1', reason: 'the first free worktree, even if proposed for another item');
    final plan = dispatcher.current!;
    expect(plan.running, 1);
    expect(plan.assignments.map((a) => a.key), ['T-0002@wt-2']);
    await expectLater(dispatcher.start('T-0001'), throwsA(isA<ClaimConflictException>()));

    await backlog.items.update('T-0002', [FieldChange.parse('status=backlog')]);
    await expectLater(
      dispatcher.start('T-0002'),
      throwsA(isA<InvalidInputException>().having((e) => e.message, 'message', contains('status backlog is not todo'))),
    );
    expect(await dispatcher.stop('T-0001'), isTrue);
  });
}

final class _NoTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}
