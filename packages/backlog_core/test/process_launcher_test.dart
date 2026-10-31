// Real processes and git: slow when `mise run check` runs every suite at once.
@Timeout(Duration(minutes: 2))
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
if [ "$2" = "--resume" ]; then session=$3; else session="sess-$id"; fi
echo "{\"type\":\"system\",\"session_id\":\"$session\"}"
echo "args $*"
echo "prompt $PROMPT"
echo "agent $BACKLOG_AGENT on $id in $(pwd) branch $(git symbolic-ref --short HEAD) backlog $BACKLOG_DIR extra $EXTRA"
sleep 30 &
echo "child $!" > "../child-$id"
while [ ! -f "../go-$id" ]; do sleep 0.05; done
code=$(cat "../go-$id")
echo "done with $code"
kill %1 2>/dev/null
exit "$code"
''';

/// How long the tests wait for the fake agent (a shell script and git) to
/// get somewhere; generous, since `mise run check` runs suites in parallel.
const _patience = Duration(seconds: 30);

/// Lets the fake agent waiting for [file] exit with [code]. Written aside and
/// renamed: the agent must never read a created but still empty file (an
/// empty code made it exit with 2 instead).
void _signalGo(String file, int code) {
  File('$file.tmp').writeAsStringSync('$code');
  File('$file.tmp').renameSync(file);
}

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
        _signalGo(path('go-$id'), 1);
      }
      // An agent may still be writing its last lines; try until it is done.
      final waited = Stopwatch()..start();
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        try {
          await root.delete(recursive: true);
          break;
        } on FileSystemException {
          if (waited.elapsed > _patience) rethrow;
        }
      }
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
      env: {EXTRA: "{worktree}/{branch}", PROMPT: "{prompt}"}
      output: claude-stream-json
      resume: [--resume, "{session}"]
  resume_prompt: "Continue {id}: {news}"
  actions:
    - name: Fix
      statuses: [review]
      prompt: "Fix it on {branch}"
    - name: Review
      statuses: [review]
      fresh: true
      prompt: "Review {id}"
    - name: Check
      statuses: [review]
      run: [sh, -c, "echo checking {id} on \$(git symbolic-ref --short HEAD) as \$BACKLOG_AGENT; echo out-line; exit 3"]
    - name: Noop
      run: noop
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
    _signalGo(path('go-$id'), code);
    final agents = by ?? launcher;
    final waited = Stopwatch()..start();
    while (waited.elapsed < _patience) {
      await agents.tick();
      if (!File(p.join(stateDir, 'agents', 'demo', '$id.json')).existsSync()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('the agent for $id did not end');
  }

  Future<String> logOf(String id) async => (await launcher.agentLog(ItemId(id)))!.lines.join('\n');

  Future<void> waitForLog(String id, String text) async {
    final waited = Stopwatch()..start();
    while (waited.elapsed < _patience) {
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
    expect((source.path, source.running, source.output), (record['log'], true, AgentOutput.claudeStreamJson));

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

  test('an epic agent takes the epic with its open children and leaves no claims on its items', () async {
    await backlog.items.create(const NewItem(title: 'Epic', type: 'epic', status: 'todo'));
    await backlog.items.create(const NewItem(title: 'One', parent: 'T-0001', status: 'todo'));
    await backlog.items.create(const NewItem(title: 'Two', parent: 'T-0001', status: 'todo'));
    await launcher.launch((await plan()).epicStart('T-0001'));
    final epic = await planned('T-0001');
    expect((epic.claim!.agent, epic.item.status, epic.item.branch), ('wt-1', 'in-progress', 'agent/T-0001'));

    // The agent works through the epic: one item handed over, one begun.
    await backlog.claims.claimInEpic('T-0001', 'wt-1');
    await backlog.items.update('T-0002', [FieldChange.parse('status=review')]);
    expect((await backlog.claims.claimInEpic('T-0001', 'wt-1')).outcome!.item.id, ItemId('T-0003'));
    final during = await plan();
    expect(during.epics, {ItemId('T-0001')});
    expect(during.worktrees.first.run!.epic, isTrue);
    expect(during.assignments, isEmpty);

    await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
    await finish('T-0001', 0);
    final handedOver = await planned('T-0002');
    expect((handedOver.item.status, handedOver.claim), ('review', null));
    final unfinished = await planned('T-0003');
    expect((unfinished.item.status, unfinished.claim), ('todo', null));
    expect(logs.last, contains('released the unfinished T-0003; dropped the claims on T-0002'));
    final after = await plan();
    expect(after.epics, {ItemId('T-0001')}, reason: 'the epic in review is still implemented as a whole');
    expect(after.assignments, isEmpty, reason: 'T-0003 stays with the epic');

    // An action that continues the epic's session (not fresh) keeps it an epic.
    await launcher.launch(after.actionStart('T-0001', 'Fix').agent!);
    await finish('T-0001', 0);
    final later = await plan();
    expect(later.epics, {ItemId('T-0001')});
    expect(later.assignments, isEmpty);
  });

  group('pull requests (dispatcher.pr)', () {
    late String remote;

    /// Adds a bare repository as origin and `dispatcher.pr` with a fake
    /// create command that records its stdin and prints [output].
    Future<void> configure(String output, {int exitCode = 0}) async {
      remote = path('remote.git');
      await _git(root.path, ['init', '-q', '--bare', '-b', 'main', remote]);
      await _git(path('repo'), ['remote', 'add', 'origin', remote]);
      File(path('fake-tea.sh')).writeAsStringSync(
        'cat > "${path('pr-stdin')}"\necho "args \$*" > "${path('pr-args')}"\necho "$output"\nexit $exitCode\n',
      );
      final config = File(p.join(path('backlog'), 'backlog.yaml'));
      config.writeAsStringSync(
        '${config.readAsStringSync()}'
        '  pr:\n    create: [sh, ${path('fake-tea.sh')}, --head, "{branch}", --base, "{base}"]\n',
      );
      backlog = await Backlog.open(path('backlog'), clock: clock, ids: SequentialIds());
    }

    Future<void> handOver({bool commit = true, String? message}) async {
      await backlog.items.create(const NewItem(title: 'Usage section', status: 'todo'));
      await launcher.launch((await plan()).assignmentFor('T-0001'));
      await waitForLog('T-0001', 'agent wt-1');
      if (commit) {
        File(path('wt-1/USAGE.md')).writeAsStringSync('Run it.\n');
        await _git(path('wt-1'), ['add', '.']);
        await _git(path('wt-1'), ['-c', 'user.email=a@b', '-c', 'user.name=A', 'commit', '-q', '-m', 'Usage (T-0001)']);
      }
      if (message != null) {
        final log = (await launcher.agentLogSource(ItemId('T-0001')))!.path;
        File(log).writeAsStringSync(
          '${jsonEncode({'type': 'result', 'result': message, 'session_id': 'sess-T-0001'})}\n',
          mode: FileMode.append,
        );
      }
      await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
      await finish('T-0001', 0);
    }

    test('an agent in review without a pull request gets one from the launcher', () async {
      await configure('Created https://git.example/o/r/pulls/5');
      await handOver(message: 'Adds a usage section.\n\nChecked the README renders.');

      final after = await planned('T-0001');
      expect(after.item.status, 'review');
      expect(after.item.pr, 'https://git.example/o/r/pulls/5');
      expect(await _git(remote, ['log', '-1', '--format=%s', 'agent/T-0001']), 'Usage (T-0001)');
      expect(File(path('pr-args')).readAsStringSync().trim(), 'args --head agent/T-0001 --base main');
      expect(
        File(path('pr-stdin')).readAsStringSync(),
        'Adds a usage section.\n\nChecked the README renders.\n\nBacklog item: T-0001',
        reason: 'the description is the agent\'s last message',
      );
      final note = Discussion.parse(after.item.body).comments.single;
      expect((note.author, note.note), ('dispatcher', true));
      expect(note.text, contains('opened https://git.example/o/r/pulls/5'));
      expect(logs.last, contains('opened its pull request https://git.example/o/r/pulls/5'));
    });

    test('when that fails, a note says why and the item stays in review', () async {
      await configure('fatal: unable to connect', exitCode: 1);
      await handOver();

      final after = await planned('T-0001');
      expect(after.item.status, 'review');
      expect(after.item.pr, isNull);
      final note = Discussion.parse(after.item.body).comments.single;
      expect(note.note, isTrue, reason: 'a note does not wake the agent');
      expect(note.text, allOf(contains('Could not open a pull request'), contains('unable to connect')));
      expect(note.text, contains('`backlog pr T-0001` in wt-1 tries again'));
    });

    test('no pull request for a branch without commits, nor for an item that has one', () async {
      await configure('https://git.example/o/r/pulls/5');
      await handOver(commit: false);
      expect(Discussion.parse((await planned('T-0001')).item.body).comments.single.text, contains('no commits'));
      expect(File(path('pr-args')).existsSync(), isFalse);

      await backlog.items.update('T-0001', [FieldChange.parse('pr=https://git.example/o/r/pulls/1')]);
      await backlog.items.update('T-0001', [FieldChange.parse('status=todo')]);
      File(path('go-T-0001')).deleteSync();
      await launcher.launch((await plan()).assignmentFor('T-0001'));
      await waitForLog('T-0001', 'agent wt-1');
      File(path('wt-1/MORE.md')).writeAsStringSync('More.\n');
      await _git(path('wt-1'), ['add', '.']);
      await _git(path('wt-1'), ['-c', 'user.email=a@b', '-c', 'user.name=A', 'commit', '-q', '-m', 'More (T-0001)']);
      await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
      await finish('T-0001', 0);
      expect(logs.last, contains('handed over as review'));
      expect(File(path('pr-args')).existsSync(), isFalse);
      expect((await planned('T-0001')).item.pr, 'https://git.example/o/r/pulls/1');
    });
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
    expect(again.starts[ItemId('T-0001')]?.worktree, 'wt-1', reason: 'the start is known for replies');

    // A person starts it again: that lifts the hold.
    await launcher.launch(again.assignmentFor('T-0001'));
    expect((await plan()).held, isEmpty);
    await finish('T-0001', 0);
  });

  test('starting the item again continues its last session in the same worktree, or fresh', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    await launcher.launch((await plan()).assignmentFor('T-0001'));
    await finish('T-0001', 3);
    final last = (await launcher.agentLog(ItemId('T-0001')))!.last!;
    expect(last['session_id'], 'sess-T-0001');

    // The other worktree is preferred by nothing; still the session's own one is taken.
    final again = await plan();
    expect(again.sessions[ItemId('T-0001')]!.worktree, 'wt-1');
    final resumed = again.assignmentFor('T-0001');
    expect(resumed.key, 'T-0001@wt-1+resume');
    clock.advance(const Duration(minutes: 1)); // a log of its own
    await launcher.launch(resumed);
    await waitForLog('T-0001', 'agent wt-1');
    final log = await logOf('T-0001');
    expect(log, contains('resuming session sess-T-0001'));
    expect(log, contains('args T-0001 --resume sess-T-0001'));
    expect(log, contains('prompt Continue T-0001: your last run exited with code 3; it left in-progress'));
    await finish('T-0001', 3);
    expect((await launcher.agentLog(ItemId('T-0001')))!.last!['session_id'], 'sess-T-0001');

    final fresh = (await plan()).assignmentFor('T-0001', fresh: true);
    expect(fresh.resume, isNull);
    clock.advance(const Duration(minutes: 1));
    await launcher.launch(fresh);
    await waitForLog('T-0001', 'agent wt-1');
    expect(await logOf('T-0001'), contains('args T-0001\n'));
    await finish('T-0001', 0);
  });

  test('an agent that asked a question releases its item without a hold; it waits for a person', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    await launcher.launch((await plan()).assignmentFor('T-0001'));
    await backlog.items.comment('T-0001', author: 'wt-1', text: 'CSV or JSON?', question: true);
    await finish('T-0001', 0);

    final item = await planned('T-0001');
    expect(item.item.status, 'todo');
    expect(item.claim, isNull);
    expect(item.needsHuman, isTrue);
    expect(logs.last, contains('it asked a question; released, waits for a person to answer'));
    var next = await plan();
    expect(next.held, isEmpty);
    expect(next.assignments, isEmpty, reason: 'it is not ready while it needs a person');
    expect(() => next.assignmentFor('T-0001'), throwsA(isA<InvalidInputException>()));

    clock.advance(const Duration(minutes: 5));
    await backlog.items.comment('T-0001', author: 'tobik', text: 'CSV.');
    next = await plan();
    expect(next.assignments.single.key, 'T-0001@wt-1+resume');
    await launcher.launch(next.assignments.single);
    await waitForLog('T-0001', 'agent wt-1');
    final log = await logOf('T-0001');
    expect(log, contains('args T-0001 --resume sess-T-0001'));
    expect(log, contains('### tobik · 2026-10-31 12:05:00 UTC\n\nCSV.'));
    expect(log, isNot(contains('CSV or JSON?')), reason: 'its own question is not news');
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
    final waited = Stopwatch()..start();
    while (!File(path('child-T-0001')).existsSync() && waited.elapsed < _patience) {
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

  group('the branch checked out in another worktree', () {
    Future<List<Comment>> notes() async =>
        (await planned('T-0001')).item.discussion.comments.where((c) => c.author == 'kanban-ai').toList();

    /// T-0001 left unfinished by its agent in wt-1 (its session lives there),
    /// then its branch checked out in wt-2 (as a fresh review would).
    Future<void> branchInWt2() async {
      await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
      await launcher.launch((await plan()).assignmentFor('T-0001'));
      await finish('T-0001', 3);
      await _git(path('wt-1'), ['switch', '-q', '--detach']);
      await _git(path('wt-2'), ['switch', '-q', 'agent/T-0001']);
      clock.advance(const Duration(minutes: 5));
      await backlog.items.comment('T-0001', author: 'tobik', text: 'Go on.');
    }

    test('a free, clean worktree of the dispatcher is detached and the agent starts', () async {
      await branchInWt2();
      final resume = (await plan()).assignments.single;
      expect(resume.key, 'T-0001@wt-1+resume');
      await launcher.launch(resume);
      expect(await ProcessAgentLauncher.worktreeBranch(path('wt-2')), isNull);
      await waitForLog('T-0001', 'agent wt-1');
      expect(await logOf('T-0001'), contains('in ${path('wt-1')} branch agent/T-0001'));
      expect(logs, contains(contains('detached wt-2 from agent/T-0001 for T-0001 in wt-1')));
      await finish('T-0001', 0);
    });

    test('a busy or dirty one is not touched: the item is held once, even for replies, until it is free', () async {
      await branchInWt2();
      File(path('wt-2/scratch.txt')).writeAsStringSync('x');
      final resume = (await plan()).assignments.single;
      await expectLater(launcher.launch(resume), throwsA(isA<UnavailableException>()));
      expect(await ProcessAgentLauncher.worktreeBranch(path('wt-2')), 'agent/T-0001');
      expect((await planned('T-0001')).claim, isNull);
      expect((await notes()).single.text, contains('the branch agent/T-0001 is checked out in the worktree wt-2'));

      // No loop: the reply does not start it again by itself.
      var next = await plan();
      expect(next.assignments, isEmpty);
      expect(next.held.single.reason, contains('which has uncommitted changes'));
      // Starting it by hand fails the same way, without another note.
      await expectLater(launcher.launch(next.assignmentFor('T-0001')), throwsA(isA<UnavailableException>()));
      expect(await notes(), hasLength(1));

      // Busy (a live claim under its name) is no better than dirty.
      File(path('wt-2/scratch.txt')).deleteSync();
      await backlog.items.create(const NewItem(title: 'B', status: 'todo'));
      await backlog.claims.claim('T-0002', 'wt-2');
      next = await plan();
      expect(next.assignments.map((a) => a.key), isNot(contains(startsWith('T-0001'))));
      expect(next.held.map((h) => h.item.id), contains(ItemId('T-0001')));

      // Free and clean: the hold goes away and the reply starts the agent, which frees the branch.
      await backlog.claims.release('T-0002', agent: 'wt-2');
      next = await plan();
      final again = next.assignments.firstWhere((a) => a.id == ItemId('T-0001'));
      expect(again.key, 'T-0001@wt-1+resume');
      await launcher.launch(again);
      expect(await ProcessAgentLauncher.worktreeBranch(path('wt-2')), isNull);
      await finish('T-0001', 3);
      expect(await notes(), hasLength(1));
    });

    test('a prompt action fails for good instead of waiting', () async {
      await branchInWt2();
      File(path('wt-2/scratch.txt')).writeAsStringSync('x');
      await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
      final start = (await plan()).actionStart('T-0001', 'Fix').agent!;
      await expectLater(launcher.launch(start), throwsA(isA<InvalidInputException>()));
      expect(
        File(p.join(stateDir, 'agents', 'demo', 'T-0001.hold.json')).existsSync(),
        isTrue,
        reason: 'the hold of the unfinished agent stays',
      );
      expect((await planned('T-0001')).claim, isNull);
    });
  });

  group('actions', () {
    /// T-0001 worked on by an agent in wt-1 and handed over for review.
    Future<void> reviewed() async {
      await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
      await launcher.launch((await plan()).assignmentFor('T-0001'));
      await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
      await finish('T-0001', 0);
    }

    Future<List<Comment>> notes() async =>
        (await planned('T-0001')).item.discussion.comments.where((c) => c.author == 'kanban-ai').toList();

    test('a prompt action continues the item session, keeps the status and drops its claim', () async {
      await reviewed();
      final start = (await plan()).actionStart('T-0001', 'Fix').agent!;
      expect(start.resume!.id, 'sess-T-0001');
      await launcher.launch(start);

      final running = await planned('T-0001');
      expect(running.claim!.agent, 'wt-1');
      expect(running.item.status, 'review', reason: 'an action does not take the item over');
      expect((await plan()).runFor(ItemId('T-0001'))!.action, 'Fix');
      await waitForLog('T-0001', 'args T-0001 --resume sess-T-0001');
      expect(await logOf('T-0001'), contains('action "Fix" on backlog item T-0001'));
      await finish('T-0001', 0);

      final after = await planned('T-0001');
      expect((after.item.status, after.claim), ('review', null));
      expect(File(p.join(stateDir, 'agents', 'demo', 'T-0001.hold.json')).existsSync(), isFalse);
      // A successful agent leaves no note of its own: the discussion stays for questions and answers.
      expect(await notes(), isEmpty);
      expect((await plan()).sessions[ItemId('T-0001')]!.id, 'sess-T-0001', reason: 'still the item session');
    });

    test('a prompt action whose agent fails leaves a note', () async {
      await reviewed();
      await launcher.launch((await plan()).actionStart('T-0001', 'Fix').agent!);
      await finish('T-0001', 3);
      expect((await notes()).single.text, startsWith('The action "Fix" (agent fake in wt-1) exited with code 3 after'));
      expect((await notes()).single.note, isTrue);
    });

    test('a fresh prompt action is a side session that does not replace the item session', () async {
      await reviewed();
      final itemRun = (await plan()).sessions[ItemId('T-0001')]!.startedAt;
      final start = (await plan()).actionStart('T-0001', 'Review').agent!;
      expect((start.worktree.name, start.resume), ('wt-1', null), reason: 'where the branch is checked out');
      await launcher.launch(start);
      await finish('T-0001', 0);
      expect((await plan()).sessions[ItemId('T-0001')]!.startedAt, itemRun);
      final last = (await launcher.agentLog(ItemId('T-0001')))!;
      expect(last.last!['action'], 'Review', reason: 'the log of the latest run');
    });

    test('a command runs in the item worktree and reports its result as a note', () async {
      await reviewed();
      final job = (await plan()).actionStart('T-0001', 'Check').job!;
      expect(job.worktree, 'wt-1');
      await launcher.runJob(job);
      final busy = await plan();
      expect(busy.worktrees.first.isBusy, isTrue);
      expect(busy.runFor(ItemId('T-0001'))!.kind, RunKind.command);
      expect(() => busy.actionStart('T-0001', 'Fix'), throwsA(isA<UnavailableException>()));
      await finish('T-0001', 0);

      final note = (await notes()).single;
      expect(note.text, startsWith('The action "Check" (wt-1) exited with code 3 after'));
      expect(note.text, contains('checking T-0001 on agent/T-0001 as wt-1\nout-line\n```'));
      final after = await planned('T-0001');
      expect((after.item.status, after.claim), ('review', null));
      expect((await launcher.agentLog(ItemId('T-0001')))!.lines, contains('out-line'));
      expect((await plan()).sessions[ItemId('T-0001')]!.id, 'sess-T-0001');
    });

    test('a built-in runs inside the server; after a restart it counts as interrupted', () async {
      await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
      await launcher.runJob((await plan()).actionStart('T-0001', 'Noop').job!);
      await finish('T-0001', 0);
      expect(
        (await notes()).single.text,
        startsWith('The action "Noop" (backlog) succeeded: did nothing (noop) after'),
      );
      expect(await logOf('T-0001'), contains('noop: nothing to do for T-0001'));

      final hanging = ProcessAgentLauncher(
        project: 'demo',
        backlog: () async => backlog,
        stateDir: stateDir,
        clock: clock,
        builtIns: {'noop': _Hanging()},
      );
      await hanging.runJob((await plan()).actionStart('T-0001', 'Noop').job!);
      await expectLater(hanging.stop(ItemId('T-0001')), throwsA(isA<InvalidInputException>()));
      await hanging.close();
      await finish('T-0001', 0); // a new launcher, as after a restart
      expect((await notes()).last.text, startsWith('The action "Noop" (backlog) was interrupted (the server stopped'));
    });
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

/// A built-in action that never ends.
final class _Hanging implements BuiltInAction {
  @override
  String get name => 'noop';

  @override
  Future<BuiltInActionResult> run(BuiltInActionContext context) => Completer<BuiltInActionResult>().future;
}
