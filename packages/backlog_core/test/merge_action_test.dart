@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// The built-in action `merge` against real git repositories: a primary
/// clone `repo` on main, a bare `origin`, the listed worktree `wt-1` and
/// `wt-2`, which the dispatcher "created" (it has a record).
void main() {
  late Directory root;
  late Backlog backlog;
  late String stateDir;
  late List<String> log;

  String path(String name) => p.join(root.path, name);

  Future<String> git(String dir, List<String> arguments) async {
    final result = await Process.run('git', [
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      ...arguments,
    ], workingDirectory: dir);
    if (result.exitCode != 0) throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
    return '${result.stdout}'.trim();
  }

  Future<void> commit(String dir, String file, String text, String message) async {
    File(p.join(dir, file)).writeAsStringSync(text);
    await git(dir, ['add', file]);
    await git(dir, ['commit', '-q', '-m', message]);
  }

  /// Writes backlog.yaml with [merge] (the `dispatcher.merge` section) and
  /// [pr] (`dispatcher.pr`) and opens it.
  Future<void> configure({String merge = '{strategy: local}', String? pr}) async {
    File(p.join(path('backlog'), 'backlog.yaml')).writeAsStringSync('''
id: {prefix: T}
statuses:
  - {id: todo, category: open, pickable: true}
  - {id: in-progress, category: active}
  - {id: review, category: active}
  - {id: deploy, category: active}
  - {id: done, category: done}
dispatcher:
  worktrees: [wt-1]
  repo: ../repo
  max_worktrees: 3
  actions:
    - name: Merge
      on_enter: deploy
      statuses: [review]
      run: merge
  merge: $merge
${pr == null ? '' : '  pr: $pr\n'}''');
    backlog = await Backlog.open(
      path('backlog'),
      clock: FixedClock(DateTime.utc(2026, 10, 31, 12)),
      ids: SequentialIds(),
    );
  }

  /// T-0001 in deploy, with one commit on agent/T-0001 checked out in [worktree]
  /// (none: the branch exists but is checked out nowhere).
  Future<String> item({String? worktree = 'wt-1', String file = 'feature.txt', String text = 'feature\n'}) async {
    await backlog.items.create(const NewItem(title: 'Feature', status: 'deploy'));
    await backlog.items.update('T-0001', [FieldChange.parse('branch=agent/T-0001')]);
    final dir = path(worktree ?? 'wt-1');
    await git(dir, ['switch', '-q', '-c', 'agent/T-0001', 'main']);
    await commit(dir, file, text, 'Feature (T-0001)');
    final tip = await git(dir, ['rev-parse', 'HEAD']);
    if (worktree == null) await git(dir, ['switch', '-q', '--detach', 'main']);
    return tip;
  }

  Future<DispatchPlan> plan() async {
    final snapshot = await backlog.planning.snapshot();
    final launcher = WorktreeProvisioner(
      ProcessAgentLauncher(project: 'demo', backlog: () async => backlog, stateDir: stateDir),
      project: 'demo',
      stateDir: stateDir,
    );
    return DispatchPlan.of(
      snapshot,
      backlogRoot: backlog.root,
      conditions: await launcher.conditions(snapshot.workflow.dispatcher!, backlog.root, snapshot),
    )!;
  }

  Future<BuiltInActionResult> merge({ActionTrigger trigger = ActionTrigger.onEnter, String? from = 'review'}) async {
    final job = (await plan()).actionStart('T-0001', 'Merge', trigger: trigger, from: from).job!;
    return const MergeAction().run(
      BuiltInActionContext(
        item: job.item,
        action: job.action,
        config: backlog.workflow.dispatcher!,
        backlog: backlog,
        backlogRoot: backlog.root,
        worktree: job.worktree,
        path: job.path,
        values: job.values,
        environment: {...Platform.environment, ...job.environment},
        log: log.add,
        trigger: trigger,
        from: from,
        stateDir: stateDir,
        project: 'demo',
      ),
    );
  }

  Future<Item> current() => backlog.items.get('T-0001');

  Future<List<Comment>> comments() async => (await current()).discussion.comments;

  Future<bool> hasBranch(String name) async =>
      (await Process.run('git', [
        'rev-parse',
        '--verify',
        '--quiet',
        'refs/heads/$name',
      ], workingDirectory: path('repo'))).exitCode ==
      0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('merge_action_');
    addTearDown(() => root.delete(recursive: true));
    stateDir = path('state');
    log = [];
    final repo = path('repo');
    await git(root.path, ['init', '-q', '--bare', '-b', 'main', path('origin.git')]);
    await git(root.path, ['init', '-q', '-b', 'main', repo]);
    await commit(repo, 'README.md', 'one\ntwo\nthree\n', 'Initial commit');
    await git(repo, ['remote', 'add', 'origin', path('origin.git')]);
    await git(repo, ['push', '-q', 'origin', 'main']);
    for (final worktree in ['wt-1', 'wt-2']) {
      await git(repo, ['worktree', 'add', '-q', '--detach', path(worktree)]);
    }
    final records = Directory(p.join(stateDir, 'worktrees', 'demo'))..createSync(recursive: true);
    File(p.join(records.path, 'wt-2.json')).writeAsStringSync(
      jsonEncode({
        'name': 'wt-2',
        'path': path('wt-2'),
        'repo': repo,
        'created_at': '2026-10-31T10:00:00.000Z',
        'last_used': '2026-10-31T10:00:00.000Z',
      }),
    );
    await Backlog.init(path('backlog'));
    await configure();
  });

  group('local', () {
    test('fast-forwards main, marks the item done and cleans up the listed worktree', () async {
      final tip = await item();
      final agents = Directory(p.join(stateDir, 'agents', 'demo'))..createSync(recursive: true);
      File(p.join(agents.path, 'T-0001.last.json')).writeAsStringSync(jsonEncode({'session_id': 's-1', 'log': 'x'}));

      final result = await merge();
      expect(result.ok, isTrue, reason: result.summary);
      expect(result.summary, startsWith('merged agent/T-0001 into main (fast-forward); T-0001 is done'));
      expect(
        result.summary,
        contains('wt-1 is back on main; deleted the branch agent/T-0001; dropped the agent session'),
      );
      expect(await git(path('repo'), ['rev-parse', 'main']), tip);
      expect(File(path('repo/feature.txt')).existsSync(), isTrue, reason: 'the primary clone is on main');
      expect((await current()).status, 'done');
      expect(await hasBranch('agent/T-0001'), isFalse);
      expect(await git(path('wt-1'), ['rev-parse', 'HEAD']), tip);
      expect(Directory(path('wt-1')).existsSync(), isTrue, reason: 'a listed worktree stays');
      expect(
        jsonDecode(File(p.join(agents.path, 'T-0001.last.json')).readAsStringSync()),
        containsPair('session_id', null),
      );
      expect(await comments(), isEmpty);
      expect(await git(path('origin.git'), ['log', '-1', '--format=%s', 'main']), 'Initial commit');
    });

    test('rebases onto a newer main, runs the check and pushes', () async {
      await configure(
        merge: '{strategy: local, check: [sh, -c, "test -f feature.txt && test -f other.txt"], push: true}',
      );
      await item();
      await commit(path('repo'), 'other.txt', 'other\n', 'Meanwhile on main');

      final result = await merge();
      expect(result.ok, isTrue, reason: '${result.summary}\n${log.join('\n')}');
      expect(result.summary, contains('(fast-forward, rebased onto main, checked, pushed main to origin)'));
      expect(
        await git(path('repo'), ['log', '--format=%s', 'main']),
        'Feature (T-0001)\nMeanwhile on main\nInitial commit',
      );
      expect(await git(path('origin.git'), ['rev-parse', 'main']), await git(path('repo'), ['rev-parse', 'main']));
      expect((await current()).status, 'done');
    });

    test('a conflict aborts the rebase and sends the item back to review with a comment', () async {
      final tip = await item(file: 'README.md', text: 'one\nTWO\nthree\n');
      await commit(path('repo'), 'README.md', 'one\n2\nthree\n', 'Conflicting change');
      final main = await git(path('repo'), ['rev-parse', 'main']);

      final result = await merge();
      expect(result.ok, isFalse);
      expect(result.summary, 'rebasing agent/T-0001 onto main conflicts in README.md; T-0001 went back to review');
      expect((await current()).status, 'review');
      final comment = (await comments()).single;
      expect((comment.author, comment.note), ('kanban-ai', false), reason: 'the agent is to fix it');
      expect(comment.text, startsWith('Merging agent/T-0001 into main (local) failed: rebasing'));
      expect(
        comment.text,
        contains(
          'To fix it, in the worktree of agent/T-0001:\n\n'
          '1. `git rebase main` on agent/T-0001\n'
          '2. resolve the conflicts git reports, `git add <file>` for each resolved file, then '
          '`git rebase --continue` (repeat until the rebase is done; never `git rebase --abort` or `--skip`)\n'
          '3. run the project\'s checks and commit what it needs\n'
          '4. leave T-0001 in review: do not change its status\n\n',
        ),
        reason: 'no fetch and no pull request without a remote strategy and pr',
      );
      expect(comment.text, contains('Then move it to deploy again to merge it.'));
      expect(await git(path('wt-1'), ['rev-parse', 'HEAD']), tip, reason: 'the branch is as before');
      expect(await git(path('wt-1'), ['status', '--porcelain']), isEmpty, reason: 'no rebase left behind');
      expect(await git(path('repo'), ['rev-parse', 'main']), main);
      expect(await hasBranch('agent/T-0001'), isTrue);
    });

    test('a failing check after a rebase restores the branch', () async {
      await configure(merge: '{strategy: local, check: [sh, -c, "echo broken build; exit 2"]}');
      final tip = await item();
      await commit(path('repo'), 'other.txt', 'other\n', 'Meanwhile on main');
      final main = await git(path('repo'), ['rev-parse', 'main']);

      final result = await merge();
      expect(result.ok, isFalse);
      expect(result.summary, contains('failed with exit code 2 (after the rebase onto main)'));
      expect((await current()).status, 'review');
      final comment = (await comments()).single;
      expect(comment.text, contains('```text\nbroken build\n```'));
      expect(comment.text, contains("3. run `sh -c 'echo broken build; exit 2'` and commit what it needs\n"));
      expect(await git(path('wt-1'), ['rev-parse', 'HEAD']), tip);
      expect(await git(path('repo'), ['rev-parse', 'main']), main);
    });

    test('uncommitted changes in the primary clone stop it before anything happens', () async {
      final tip = await item();
      File(path('repo/README.md')).writeAsStringSync('local edit\n');

      final result = await merge();
      expect(result.ok, isFalse);
      expect(result.summary, contains('has uncommitted changes to tracked files'));
      expect((await current()).status, 'review');
      expect((await comments()).single.note, isTrue, reason: 'for a person, not the agent');
      expect(await git(path('wt-1'), ['rev-parse', 'HEAD']), tip);
    });

    test('a hook whose item was last seen in an open status sends it back to the active status before', () async {
      await item(file: 'README.md', text: 'x\n');
      await commit(path('repo'), 'README.md', 'y\n', 'Conflicting change');
      final result = await merge(from: 'todo');
      expect(result.summary, endsWith('T-0001 went back to review'));
      expect((await current()).status, 'review');
    });

    test('a button (not the hook) leaves a failed item where it is', () async {
      await item(file: 'README.md', text: 'x\n');
      await commit(path('repo'), 'README.md', 'y\n', 'Conflicting change');
      await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
      final result = await merge(trigger: ActionTrigger.request, from: null);
      expect((result.ok, result.summary.contains('went back')), (false, false));
      expect((await current()).status, 'review');
      expect((await comments()).single.text, contains('run the action "Merge" again'));
    });

    test(
      'a worktree the dispatcher created is removed; a branch checked out nowhere is merged in a temporary one',
      () async {
        await item(worktree: 'wt-2');
        expect((await merge()).ok, isTrue);
        expect(Directory(path('wt-2')).existsSync(), isFalse);
        expect(File(p.join(stateDir, 'worktrees', 'demo', 'wt-2.json')).existsSync(), isFalse);
        expect(await hasBranch('agent/T-0001'), isFalse);

        await backlog.items.create(const NewItem(title: 'Second', status: 'deploy'));
        await backlog.items.update('T-0002', [FieldChange.parse('branch=agent/T-0002')]);
        await git(path('wt-1'), ['switch', '-q', '-c', 'agent/T-0002', 'main']);
        await commit(path('wt-1'), 'second.txt', '2\n', 'Second (T-0002)');
        await git(path('wt-1'), ['switch', '-q', '--detach', 'main']);
        await commit(path('repo'), 'other.txt', 'other\n', 'Meanwhile on main');
        final job = (await plan()).actionStart('T-0002', 'Merge', trigger: ActionTrigger.onEnter).job!;
        expect(job.worktree, isNull, reason: 'checked out nowhere');
        final result = await const MergeAction().run(
          BuiltInActionContext(
            item: job.item,
            action: job.action,
            config: backlog.workflow.dispatcher!,
            backlog: backlog,
            backlogRoot: backlog.root,
            path: job.path,
            values: job.values,
            environment: Platform.environment,
            log: log.add,
            trigger: ActionTrigger.onEnter,
            stateDir: stateDir,
            project: 'demo',
          ),
        );
        expect(result.ok, isTrue, reason: result.summary);
        expect(result.summary, contains('rebased onto main'));
        expect(Directory(path('repo-merge-T-0002')).existsSync(), isFalse, reason: 'the temporary worktree is gone');
        expect(await git(path('repo'), ['log', '-1', '--format=%s', 'main']), 'Second (T-0002)');
        expect(await hasBranch('agent/T-0002'), isFalse);
      },
    );

    test('cleanup: false leaves branch and worktree', () async {
      await configure(merge: '{strategy: local, cleanup: false}');
      await item(worktree: 'wt-2');
      final result = await merge();
      expect((result.ok, (await current()).status), (true, 'done'));
      expect(Directory(path('wt-2')).existsSync(), isTrue);
      expect(await hasBranch('agent/T-0001'), isTrue);
    });
  });

  group('pr', () {
    /// A fake `tea`: records its arguments, prints [output], exits with [code].
    String fakeTea(String output, {int code = 0}) {
      File(path('tea.sh')).writeAsStringSync('echo "\$*" >> "${path('tea-calls')}"\necho "$output"\nexit $code\n');
      return '{create: [sh, ${path('tea.sh')}], merge: [sh, ${path('tea.sh')}, pulls, merge, --style, rebase, "{pr_number}"]}';
    }

    test('merges the pull request with pr.merge; the pushed branch and the created worktree go', () async {
      await configure(merge: '{strategy: pr}', pr: fakeTea('Merged'));
      await item(worktree: 'wt-2');
      await git(path('wt-2'), ['push', '-q', '--set-upstream', 'origin', 'agent/T-0001']);
      await backlog.items.update('T-0001', [FieldChange.parse('pr=https://git.example/o/r/pulls/12')]);

      final result = await merge();
      expect(result.ok, isTrue, reason: result.summary);
      expect(result.summary, startsWith('merged the pull request https://git.example/o/r/pulls/12; T-0001 is done'));
      expect(File(path('tea-calls')).readAsStringSync().trim(), 'pulls merge --style rebase 12');
      expect((await current()).status, 'done');
      expect(Directory(path('wt-2')).existsSync(), isFalse);
      expect(await hasBranch('agent/T-0001'), isFalse, reason: 'everything of it was pushed');
    });

    test('a branch with commits that were not pushed is kept', () async {
      await configure(merge: '{strategy: pr}', pr: fakeTea('Merged'));
      await item();
      await backlog.items.update('T-0001', [FieldChange.parse('pr=https://git.example/o/r/pulls/12')]);
      final result = await merge();
      expect(result.ok, isTrue);
      expect(
        result.summary,
        contains('kept the branch agent/T-0001: it has commits that are neither in main nor pushed'),
      );
      expect(await hasBranch('agent/T-0001'), isTrue);
    });

    test('a refused merge sends the item back with the output; no pr is a note', () async {
      await configure(merge: '{strategy: pr}', pr: fakeTea('Pull request is not mergeable', code: 1));
      await item();
      final none = await merge();
      expect((none.ok, (await comments()).single.note), (false, true));
      expect(none.summary, contains('has no pull request to merge'));

      await backlog.items.update('T-0001', [
        FieldChange.parse('status=deploy'),
        FieldChange.parse('pr=https://git.example/o/r/pulls/12'),
      ]);
      final refused = await merge();
      expect(refused.ok, isFalse);
      expect(
        refused.summary,
        'merging the pull request https://git.example/o/r/pulls/12 failed with exit code 1; T-0001 went back to review',
      );
      final comment = (await comments()).last;
      expect(comment.note, isFalse);
      expect(comment.text, contains('Pull request is not mergeable'));
      expect(comment.text, contains('1. `git fetch origin`\n2. `git rebase origin/main` on agent/T-0001\n'));
      expect(comment.text, contains('5. publish the branch with `backlog pr T-0001 --force` (never `git push`)\n'));
      expect(await hasBranch('agent/T-0001'), isTrue);
    });
  });

  test('through the launcher: the result is a note, the run is shown while it lasts', () async {
    await item(worktree: 'wt-2');
    final launcher = ProcessAgentLauncher(project: 'demo', backlog: () async => backlog, stateDir: stateDir);
    addTearDown(launcher.close);
    final job = (await plan()).actionStart('T-0001', 'Merge', trigger: ActionTrigger.onEnter, from: 'review').job!;
    expect(job.worktree, 'wt-2');
    await launcher.runJob(job);
    for (var i = 0; i < 100 && File(p.join(stateDir, 'agents', 'demo', 'T-0001.json')).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await launcher.tick();
    }
    final note = (await comments()).single;
    expect(note.note, isTrue);
    expect(
      note.text,
      allOf(
        startsWith('The action "Merge" (wt-2) succeeded: merged agent/T-0001 into main (fast-forward); T-0001 is done'),
        contains('removed the worktree wt-2'),
      ),
    );
    expect((await current()).status, 'done');
    expect(await launcher.agentLog(ItemId('T-0001')), isNotNull);
  });

  group('pull requests merged outside the board (pr.state)', () {
    late FixedClock clock;
    late ProcessAgentLauncher launcher;

    /// `pr.state` prints the content of the file `state` (and counts its calls).
    Future<void> watch() async {
      File(path('state.sh')).writeAsStringSync('echo "\$1" >> "${path('state-calls')}"\ncat "${path('pr-state')}"\n');
      await configure(
        merge: '{strategy: pr}',
        pr: '{create: x, merge: x, state: [sh, ${path('state.sh')}, "{pr_number}"], state_every: 2}',
      );
      clock = FixedClock(DateTime.utc(2026, 10, 31, 12));
      launcher = ProcessAgentLauncher(project: 'demo', backlog: () async => backlog, stateDir: stateDir, clock: clock);
      addTearDown(launcher.close);
      await item(worktree: 'wt-2');
      await git(path('wt-2'), ['push', '-q', '--set-upstream', 'origin', 'agent/T-0001']);
      await backlog.items.update('T-0001', [
        FieldChange.parse('status=review'),
        FieldChange.parse('pr=https://git.example/o/r/pulls/12'),
      ]);
    }

    int calls() => File(path('state-calls')).existsSync() ? File(path('state-calls')).readAsLinesSync().length : 0;

    test('a merged pull request makes the item done and cleans up, at most every state_every', () async {
      await watch();
      File(path('pr-state')).writeAsStringSync('OPEN\n');
      expect(await launcher.pollPullRequests(), isEmpty);
      expect(calls(), 1);
      expect(File(path('state-calls')).readAsStringSync().trim(), '12', reason: '{pr_number}');

      File(path('pr-state')).writeAsStringSync('{"state": "closed", "merged": true}');
      clock.advance(const Duration(minutes: 1));
      expect(await launcher.pollPullRequests(), isEmpty, reason: 'too soon');
      expect(calls(), 1);

      clock.advance(const Duration(minutes: 1));
      expect(await launcher.pollPullRequests(), [ItemId('T-0001')]);
      expect((await current()).status, 'done');
      final note = (await comments()).single;
      expect(note.note, isTrue);
      expect(
        note.text,
        'The pull request https://git.example/o/r/pulls/12 was merged outside the board; T-0001 is done; '
        'removed the worktree wt-2; deleted the branch agent/T-0001.',
      );
      expect(Directory(path('wt-2')).existsSync(), isFalse);

      clock.advance(const Duration(minutes: 5));
      expect(await launcher.pollPullRequests(), isEmpty, reason: 'done items are not asked');
      expect(calls(), 2);
    });

    test('a closed pull request gets one note; items being worked on are not asked', () async {
      await watch();
      File(path('pr-state')).writeAsStringSync('closed\n');
      expect(await launcher.pollPullRequests(force: true), isEmpty);
      expect(await launcher.pollPullRequests(force: true), isEmpty);
      final note = (await comments()).single;
      expect(
        note.text,
        'The pull request https://git.example/o/r/pulls/12 was closed without being merged; T-0001 stays review.',
      );
      expect((await current()).status, 'review');

      await backlog.claims.claim('T-0001', 'someone', force: true, mirror: false);
      final before = calls();
      await launcher.pollPullRequests(force: true);
      expect(calls(), before, reason: 'a claimed item is not asked');
    });
  });

  test('PullRequestState reads words and JSON', () {
    expect(PullRequestState.parse('MERGED\n'), PullRequestState.merged);
    expect(PullRequestState.parse('state: open'), PullRequestState.open);
    expect(PullRequestState.parse('{"state":"closed","merged":false}'), PullRequestState.closed);
    expect(PullRequestState.parse('{"state":"closed","merged":true}'), PullRequestState.merged);
    expect(PullRequestState.parse('[{"state":"CLOSED","mergedAt":"2026-10-31T12:00:00Z"}]'), PullRequestState.merged);
    expect(PullRequestState.parse('{"state":"open","merged_at":null}'), PullRequestState.open);
    expect(PullRequestState.parse('404 Not Found'), PullRequestState.unknown);
  });

  test('command: an own command merges', () async {
    File(path('ship.sh')).writeAsStringSync('echo "shipping \$1"\n[ "\$1" = agent/T-0001 ]\n');
    await configure(merge: '{strategy: command, command: [sh, ${path('ship.sh')}, "{branch}"]}');
    await item();
    final result = await merge();
    expect(result.ok, isTrue, reason: result.summary);
    expect(result.summary, startsWith('merged with `sh ${path('ship.sh')} agent/T-0001`; T-0001 is done'));
    expect(log, contains('shipping agent/T-0001'));
  });
}
