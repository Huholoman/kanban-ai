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

import '../support.dart';
import 'launcher_fixture.dart';

void main() {
  setUpLauncher();

  group('pull requests (dispatcher.pr)', () {
    late String remote;

    /// Adds a bare repository as origin and `dispatcher.pr` with a fake
    /// create command that records its stdin and prints [output].
    Future<void> configure(String output, {int exitCode = 0}) async {
      remote = path('remote.git');
      await git(root.path, ['init', '-q', '--bare', '-b', 'main', remote]);
      await git(path('repo'), ['remote', 'add', 'origin', remote]);
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
        await git(path('wt-1'), ['add', '.']);
        await git(path('wt-1'), ['-c', 'user.email=a@b', '-c', 'user.name=A', 'commit', '-q', '-m', 'Usage (T-0001)']);
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
      expect(await git(remote, ['log', '-1', '--format=%s', 'agent/T-0001']), 'Usage (T-0001)');
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
      final last = (await launcher.agentLog(ItemId('T-0001')))!.last!;
      expect(last['result'], 'Adds a usage section.\n\nChecked the README renders.');
      expect(last['problems'], isEmpty);
      expect((await plan()).problems, isEmpty);
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
      expect(note.text, contains('`kanban-ai pr T-0001` in wt-1 tries again'));
      final problem = (await plan()).problems.single;
      expect(problem.item.id, ItemId('T-0001'));
      expect(
        problem.problems.single,
        allOf(startsWith('opening its pull request failed'), contains('unable to connect')),
      );
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
      await git(path('wt-1'), ['add', '.']);
      await git(path('wt-1'), ['-c', 'user.email=a@b', '-c', 'user.name=A', 'commit', '-q', '-m', 'More (T-0001)']);
      await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
      await finish('T-0001', 0);
      expect(logs.last, contains('handed over as review'));
      expect(File(path('pr-args')).existsSync(), isFalse);
      expect((await planned('T-0001')).item.pr, 'https://git.example/o/r/pulls/1');
    });
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
      await git(path('wt-1'), ['switch', '-q', '--detach']);
      await git(path('wt-2'), ['switch', '-q', 'agent/T-0001']);
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
      expect((await planned('T-0001')).item.status, 'review', reason: 'a failed start changes no status');
    });

    test("the item's agent that cannot start leaves an item in review in review", () async {
      await branchInWt2();
      File(path('wt-2/scratch.txt')).writeAsStringSync('x');
      await backlog.items.update('T-0001', [FieldChange.parse('status=review')]);
      await expectLater(launcher.launch((await plan()).assignmentFor('T-0001')), throwsA(isA<UnavailableException>()));
      final after = await planned('T-0001');
      expect((after.claim, after.item.status), (null, 'review'));
    });
  });
}
