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

    test('the agent woken in review shows it in progress and gives it back unless it hands over itself', () async {
      await reviewed();
      clock.advance(const Duration(minutes: 1));
      await backlog.items.comment('T-0001', author: 'tobik', text: 'Why CSV?');
      File(path('go-T-0001')).deleteSync();
      final reply = (await plan()).assignments.single;
      expect(reply.returnTo, 'review');
      await launcher.launch(reply);
      final running = await planned('T-0001');
      expect((running.item.status, running.claim!.agent), ('in-progress', 'wt-1'));
      expect((await plan()).assignments, isEmpty, reason: 'an item in progress is no ready work');
      await backlog.items.comment('T-0001', author: 'wt-1', text: 'Because the issue asks for it.');
      await finish('T-0001', 0);

      var after = await planned('T-0001');
      expect((after.item.status, after.claim, after.item.assignee), ('review', null, 'wt-1'));
      expect(logs.last, contains('it left in-progress; back to review, claim dropped'));
      expect((await plan()).held, isEmpty, reason: 'given back, not held');

      // Asked for changes, it fixes them and hands over itself.
      clock.advance(const Duration(minutes: 1));
      await backlog.items.comment('T-0001', author: 'tobik', text: 'Use JSON.');
      File(path('go-T-0001')).deleteSync();
      await launcher.launch((await plan()).assignments.single);
      await backlog.items.update('T-0001', [FieldChange.parse('status=done')]);
      await finish('T-0001', 0);
      after = await planned('T-0001');
      expect((after.item.status, after.claim), ('done', null));
    });

    test('an action that changes code shows the item in progress while it runs; others keep the status', () async {
      await reviewed();
      File(path('go-T-0001')).deleteSync();
      final start = (await plan()).actionStart('T-0001', 'Fix code').agent!;
      expect(start.returnTo, 'review');
      expect(start.prompt, contains('it shows as in progress while you work and goes back to review'));
      await launcher.launch(start);
      expect((await planned('T-0001')).item.status, 'in-progress');
      await finish('T-0001', 0);
      final after = await planned('T-0001');
      expect((after.item.status, after.claim), ('review', null));
      expect(logs.last, contains('the item went back to review, claim dropped'));
      expect((await plan()).actionStart('T-0001', 'Fix').agent!.returnTo, isNull);
    });

    test('an AI review that records no verdict is a problem with a note; one that does is not', () async {
      await reviewed();
      await launcher.launch((await plan()).actionStart('T-0001', 'AI review').agent!);
      await finish('T-0001', 0);
      expect((await notes()).single.text, contains('It recorded no review (`kanban-ai review`)'));
      expect((await plan()).problems.single.problems, ['the review was not recorded (no `kanban-ai review`)']);

      clock.advance(const Duration(minutes: 1));
      File(path('go-T-0001')).deleteSync();
      await launcher.launch((await plan()).actionStart('T-0001', 'AI review').agent!);
      await backlog.items.comment('T-0001', author: 'wt-1', text: 'Fine.', review: ReviewVerdict.ok);
      await finish('T-0001', 0);
      expect(await notes(), hasLength(1), reason: 'no new note');
      expect((await plan()).problems, isEmpty);
    });

    test('the problems of the agent stay after an action that went well, until the agent runs again', () async {
      await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
      await launcher.launch((await plan()).assignmentFor('T-0001'));
      await waitForLog('T-0001', 'agent wt-1');
      File((await launcher.agentLogSource(ItemId('T-0001')))!.path).writeAsStringSync(
        '${jsonEncode({'type': 'result', 'subtype': 'error_during_execution', 'is_error': true, 'result': 'Push failed.'})}\n',
        mode: FileMode.append,
      );
      await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
      await finish('T-0001', 0);
      const problems = ['the agent ended with an error (error_during_execution)'];

      clock.advance(const Duration(minutes: 1));
      File(path('go-T-0001')).deleteSync();
      await launcher.launch((await plan()).actionStart('T-0001', 'AI review').agent!);
      await backlog.items.comment('T-0001', author: 'wt-1', text: 'Fine.', review: ReviewVerdict.ok);
      await finish('T-0001', 0);
      expect((await plan()).problems.single.problems, problems);
      final last = (await launcher.agentLog(ItemId('T-0001')))!.last!;
      expect((last['result'], last['action']), ('Push failed.', null), reason: 'the run of the agent');

      // An action with problems of its own adds them.
      clock.advance(const Duration(minutes: 1));
      File(path('go-T-0001')).deleteSync();
      await launcher.runJob((await plan()).actionStart('T-0001', 'Check').job!);
      await finish('T-0001', 0);
      expect((await plan()).problems.single.problems, [...problems, 'the action "Check" exited with code 3']);

      // The next run of the agent replaces them.
      clock.advance(const Duration(minutes: 1));
      File(path('go-T-0001')).deleteSync();
      await launcher.launch((await plan()).actionStart('T-0001', 'Fix').agent!);
      await finish('T-0001', 0);
      expect((await plan()).problems, isEmpty);
    });

    test('git ignores the scratch folder of agents in every worktree', () async {
      await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
      await launcher.launch((await plan()).assignmentFor('T-0001'));
      final exclude = File(path('repo/.git/info/exclude')).readAsStringSync();
      expect(exclude, contains('\n/.kanban-ai/\n'));
      await Directory(path('wt-2/.kanban-ai')).create();
      File(path('wt-2/.kanban-ai/review.md')).writeAsStringSync('x');
      expect(await ProcessAgentLauncher.worktreeProblem(path('wt-2')), isNull);
      // Not even where git does not ignore it: the folder never makes a worktree dirty.
      File(path('repo/.git/info/exclude')).writeAsStringSync('');
      expect(await ProcessAgentLauncher.worktreeProblem(path('wt-2')), isNull);
      File(path('wt-2/other.md')).writeAsStringSync('x');
      expect(await ProcessAgentLauncher.worktreeProblem(path('wt-2')), 'uncommitted changes (1 paths)');
      File(path('wt-2/other.md')).deleteSync();
      File(path('repo/.git/info/exclude')).writeAsStringSync(exclude);
      await ProcessAgentLauncher.ignoreScratch(path('wt-2'));
      expect(File(path('repo/.git/info/exclude')).readAsStringSync(), exclude, reason: 'added once');
      await finish('T-0001', 0);
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
      expect((await plan()).problems.single.problems, ['the action "Check" exited with code 3']);
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

    test('what a built-in does after its run (a restart) waits for the note', () async {
      await backlog.items.create(const NewItem(title: 'A', status: 'todo'));
      final after = Completer<int>();
      final then = ProcessAgentLauncher(
        project: 'demo',
        backlog: () async => backlog,
        stateDir: stateDir,
        clock: clock,
        builtIns: {'noop': _Then(() async => after.complete((await notes()).length))},
      );
      await then.runJob((await plan()).actionStart('T-0001', 'Noop').job!);
      expect(await after.future, 1);
      expect((await notes()).single.text, startsWith('The action "Noop" (backlog) succeeded: restarting after'));
      await then.close();
    });
  });
}

/// A built-in action that does [then] after its run.
final class _Then implements BuiltInAction {
  _Then(this.then);

  final Future<void> Function() then;

  @override
  String get name => 'noop';

  @override
  Future<BuiltInActionResult> run(BuiltInActionContext context) async =>
      BuiltInActionResult(ok: true, summary: 'restarting', then: then);
}

/// A built-in action that never ends.
final class _Hanging implements BuiltInAction {
  @override
  String get name => 'noop';

  @override
  Future<BuiltInActionResult> run(BuiltInActionContext context) => Completer<BuiltInActionResult>().future;
}
