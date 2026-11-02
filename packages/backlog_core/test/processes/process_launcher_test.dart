// Real processes and git: slow when `mise run check` runs every suite at once.
@Timeout(Duration(minutes: 2))
@TestOn('linux || mac-os')
@Tags(['processes'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'launcher_fixture.dart';

void main() {
  setUpLauncher();

  test('starts a detached agent on its own branch and lets it hand over for review', () async {
    await backlog.items.create(const NewItem(title: 'Usage section', status: 'todo'));
    await backlog.items.attach('T-0001', 'shot.png', [1, 2]);
    final stale = File(path('wt-1/.kanban-ai/attachments/T-0001/old.txt'))..createSync(recursive: true);
    final assignment = (await plan()).assignmentFor('T-0001');
    await launcher.launch(assignment);
    expect(
      File(path('wt-1/.kanban-ai/attachments/T-0001/shot.png')).readAsBytesSync(),
      [1, 2],
      reason: 'the agent finds the attachments in its worktree',
    );
    expect(stale.existsSync(), isFalse);

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
    await git(path('wt-1'), ['add', '.']);
    await git(path('wt-1'), ['-c', 'user.email=a@b', '-c', 'user.name=A', 'commit', '-q', '-m', 'Usage (T-0001)']);
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
    await backlog.items.create(const NewItem(title: 'Three', parent: 'T-0001', status: 'todo'));
    await launcher.launch((await plan()).epicStart('T-0001'));
    final epic = await planned('T-0001');
    expect((epic.claim!.agent, epic.item.status, epic.item.branch), ('wt-1', 'in-progress', 'agent/T-0001'));

    // The agent works through the epic: one item handed over, one begun.
    await backlog.claims.claimInEpic('T-0001', 'wt-1');
    await backlog.items.update('T-0002', [FieldChange.parse('status=review')]);
    expect((await backlog.claims.claimInEpic('T-0001', 'wt-1')).outcome!.item.id, ItemId('T-0003'));
    // Claimed and handed over without `kanban-ai epic --next`, with its own branch field.
    await backlog.claims.claim('T-0004', 'wt-1');
    await backlog.items.update('T-0004', [
      FieldChange.parse('status=review'),
      FieldChange.parse('branch=agent/T-0004'),
    ]);
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
    expect(logs.last, contains('released the unfinished T-0003; dropped the claims on T-0002, T-0004'));
    expect((await planned('T-0004')).item.branch, 'agent/T-0001', reason: 'the epic agent did it on its branch');
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

  test('an epic run limited to a milestone keeps its scope after it ended', () async {
    await backlog.items.create(const NewItem(title: 'Epic', type: 'epic', status: 'todo'));
    await backlog.items.create(const NewItem(title: 'One', parent: 'T-0001', status: 'todo', milestone: 'v0.2'));
    await backlog.items.create(const NewItem(title: 'Two', parent: 'T-0001', status: 'todo', milestone: 'v0.3'));
    await launcher.launch((await plan()).epicStart('T-0001', milestone: 'v0.2'));
    final during = await plan();
    expect(during.worktrees.first.run!.milestone, 'v0.2');
    expect(during.epicMilestones, {ItemId('T-0001'): 'v0.2'});

    await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
    await finish('T-0001', 0);
    expect((await plan()).epicMilestones, {ItemId('T-0001'): 'v0.2'});
    // An action that continues the epic's session keeps the scope too.
    await launcher.launch((await plan()).actionStart('T-0001', 'Fix').agent!);
    await finish('T-0001', 0);
    expect((await plan()).epicMilestones, {ItemId('T-0001'): 'v0.2'});
  });

  test('denied tool calls of a run that went well are a notice, of one left unfinished a problem', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    await backlog.items.create(const NewItem(title: 'B', status: 'todo'));
    Future<Map<String, Object?>> run(String id, {required bool handOver}) async {
      await launcher.launch((await plan()).assignmentFor(id));
      await waitForLog(id, 'agent wt-');
      File((await launcher.agentLogSource(ItemId(id)))!.path).writeAsStringSync(
        '${jsonEncode({
          'type': 'result',
          'subtype': 'success',
          'is_error': false,
          'result': 'Done.',
          'permission_denials': [
            {
              'tool_name': 'Bash',
              'tool_input': {'command': 'git -C ../backlog status --short'},
            },
          ],
        })}\n',
        mode: FileMode.append,
      );
      if (handOver) await backlog.items.update(id, [FieldChange.parse('status=review')]);
      await finish(id, 0);
      return (await launcher.agentLog(ItemId(id)))!.last!;
    }

    final fine = await run('T-0001', handOver: true);
    expect(fine['problems'], isEmpty);
    expect(fine['notices'], ['a tool call was denied: Bash(git -C ../backlog status --short)']);
    expect(await logOf('T-0001'), contains('(a tool call was denied: Bash(git -C ../backlog status --short))'));
    expect((await plan()).problems, isEmpty);

    final left = await run('T-0002', handOver: false);
    expect(left['problems'], ['a tool call was denied: Bash(git -C ../backlog status --short)']);
    expect(left['notices'], isEmpty);
  });

  test('the end of a run keeps the final message and the problems: denied tools, an error ending', () async {
    await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
    await launcher.launch((await plan()).assignmentFor('T-0001'));
    await waitForLog('T-0001', 'agent wt-1');
    final log = (await launcher.agentLogSource(ItemId('T-0001')))!.path;
    File(log).writeAsStringSync(
      '${jsonEncode({
        'type': 'result',
        'subtype': 'error_max_turns',
        'is_error': true,
        'result': 'Could not push: permission denied.',
        'permission_denials': [
          {
            'tool_name': 'Bash',
            'tool_input': {'command': 'git push origin agent/T-0001'},
          },
          {'tool_name': 'WebFetch', 'tool_input': <String, Object?>{}},
        ],
      })}\n',
      mode: FileMode.append,
    );
    await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
    await finish('T-0001', 0);

    final last = (await launcher.agentLog(ItemId('T-0001')))!.last!;
    expect(last['result'], 'Could not push: permission denied.');
    final problems = [
      'the agent ended with an error (error_max_turns)',
      '2 tool calls were denied: Bash(git push origin agent/T-0001), WebFetch',
    ];
    expect(last['problems'], problems);
    final again = await plan();
    expect(again.problems.single.item.id, ItemId('T-0001'));
    expect(again.problems.single.problems, problems);

    // A person dismisses them: they no longer show, but stay in the record.
    expect(await launcher.dismissProblems(ItemId('T-0001')), isTrue);
    expect((await plan()).problems, isEmpty);
    final dismissed = (await launcher.agentLog(ItemId('T-0001')))!.last!;
    expect(dismissed['problems'], isEmpty);
    expect(dismissed['dismissed_problems'], problems);
    expect(await launcher.dismissProblems(ItemId('T-0001')), isFalse);

    // A new run replaces them; one that went well has none.
    await backlog.items.update('T-0001', [FieldChange.parse('status=todo')]);
    clock.advance(const Duration(minutes: 1));
    File(path('go-T-0001')).deleteSync();
    await launcher.launch((await plan()).assignmentFor('T-0001'));
    expect((await plan()).problems, isEmpty, reason: 'it runs');
    await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
    await finish('T-0001', 0);
    expect((await plan()).problems, isEmpty);
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
    expect((await launcher.agentLog(ItemId('T-0001')))!.last!['problems'], ['the agent exited with code 3']);
    expect(again.problems, isEmpty, reason: 'held says so already');
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
      workflow: backlog.workflow,
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
    while (!File(path('child-T-0001')).existsSync() && waited.elapsed < patience) {
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
