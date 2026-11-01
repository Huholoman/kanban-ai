// Real processes and git: slow when `mise run check` runs every suite at once.
@Timeout(Duration(minutes: 2))
@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// The built-in action `preview` against real git repositories: a primary
/// clone `repo` on main and the listed worktree `wt-1`, where T-0001's
/// branch is checked out.
void main() {
  late Directory root;
  late Backlog backlog;
  late String stateDir;
  late List<String> log;
  late _FakeServer server;

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

  Future<void> configure(String preview) async {
    File(p.join(path('backlog'), 'backlog.yaml')).writeAsStringSync('''
id: {prefix: T}
statuses:
  - {id: todo, category: open, pickable: true}
  - {id: in-progress, category: active}
  - {id: review, category: active}
  - {id: done, category: done}
dispatcher:
  worktrees: [wt-1]
  repo: ../repo
  max_worktrees: 2
  actions:
    - name: Deploy locally
      statuses: [review]
      run: preview
  preview: $preview
''');
    backlog = await Backlog.open(
      path('backlog'),
      clock: FixedClock(DateTime.utc(2026, 11, 1, 12)),
      ids: SequentialIds(),
    );
  }

  Future<BuiltInActionResult> preview() async {
    final snapshot = await backlog.planning.snapshot();
    final launcher = ProcessAgentLauncher(project: 'demo', backlog: () async => backlog, stateDir: stateDir);
    final plan = DispatchPlan.of(
      snapshot,
      backlogRoot: backlog.root,
      conditions: await launcher.conditions(snapshot.workflow.dispatcher!, backlog.root, snapshot),
    )!;
    final job = plan.actionStart('T-0001', 'Deploy locally').job!;
    return const PreviewAction().run(
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
        stateDir: stateDir,
        project: 'demo',
        server: server,
      ),
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('preview_action_');
    addTearDown(() => root.delete(recursive: true));
    stateDir = path('state');
    log = [];
    server = _FakeServer();
    final repo = path('repo');
    await git(root.path, ['init', '-q', '-b', 'main', repo]);
    await commit(repo, 'README.md', 'one\ntwo\nthree\n', 'Initial commit');
    await git(repo, ['worktree', 'add', '-q', '-b', 'agent/T-0001', path('wt-1')]);
    await commit(path('wt-1'), 'feature.txt', 'feature\n', 'Feature (T-0001)');
    await commit(repo, 'other.txt', 'other\n', 'Other work on main');
    await Backlog.init(path('backlog'));
    await configure('{check: [sh, -c, "test -f feature.txt"], server: board-preview, main_server: board-main}');
    await backlog.items.create(const NewItem(title: 'Feature', status: 'review', branch: 'agent/T-0001'));
  });

  test('rebases a copy of the branch in the preview worktree, records the preview and restarts', () async {
    final tip = await git(path('wt-1'), ['rev-parse', 'HEAD']);
    final result = await preview();
    expect(result.ok, isTrue, reason: '${result.summary}\n${log.join('\n')}');
    expect(result.summary, contains('rebased onto main, checked'));
    expect(result.summary, endsWith('the server restarts as board-preview'));

    final work = path('repo-preview');
    expect(File(p.join(work, 'feature.txt')).existsSync(), isTrue);
    expect(File(p.join(work, 'other.txt')).existsSync(), isTrue, reason: 'rebased onto main');
    expect(await git(path('wt-1'), ['rev-parse', 'HEAD']), tip, reason: 'the branch itself stays');
    expect(await git(work, ['rev-parse', '--abbrev-ref', 'HEAD']), 'HEAD', reason: 'detached');

    final state = (await FilePreviewStore(stateDir).read())!;
    expect(state.item, 'T-0001');
    expect(state.project, 'demo');
    expect(state.branch, 'agent/T-0001');
    expect(state.commit, await git(work, ['rev-parse', 'HEAD']));
    expect(state.server, 'board-preview');
    expect(state.mainServer, 'board-main');

    expect(server.restarts, isEmpty, reason: 'only after the run ended');
    await result.then!();
    expect(server.restarts, ['board-preview']);
  });

  test('a conflict changes nothing', () async {
    await commit(path('repo'), 'feature.txt', 'something else\n', 'Conflicting work on main');
    final result = await preview();
    expect(result.ok, isFalse);
    expect(result.summary, 'deploying the preview failed: conflict in feature.txt (rebasing onto main)');
    expect(await FilePreviewStore(stateDir).read(), isNull);
    expect(result.then, isNull);
    expect(await git(path('repo-preview'), ['status', '--porcelain']), isEmpty, reason: 'the rebase was aborted');
  });

  test('a failing check changes nothing', () async {
    await configure('{check: [sh, -c, "exit 3"], server: board-preview}');
    final result = await preview();
    expect(result.ok, isFalse);
    expect(result.summary, contains('the check `sh -c \'exit 3\'` failed with exit code 3'));
    expect(await FilePreviewStore(stateDir).read(), isNull);
  });

  test('a server program that does not run stops it before anything is built', () async {
    server.problem = 'cannot run board-preview';
    final result = await preview();
    expect(result.summary, 'deploying the preview failed: cannot run board-preview');
    expect(Directory(path('repo-preview')).existsSync(), isFalse);
  });

  test('without a server it only prepares, and a second preview reuses the worktree', () async {
    await configure('{}');
    expect((await preview()).summary, contains('the server does not restart'));
    final result = await preview();
    expect(result.ok, isTrue, reason: result.summary);
    expect(result.then, isNull);
    expect(await FilePreviewStore(stateDir).read(), isNull);
  });

  test('a preview of a preview keeps the main server; back to main restarts with it', () async {
    await configure('{server: board-preview}');
    await preview();
    server
      ..program = 'board-preview'
      ..preview = (await FilePreviewStore(stateDir).read())!.commit;
    await preview();
    server.preview = (await FilePreviewStore(stateDir).read())!.commit;
    final local = LocalPreview(store: FilePreviewStore(stateDir), server: server);
    expect((await local.current())!.mainServer, 'board-main');

    final ended = await local.backToMain(delay: Duration.zero);
    expect(ended.item, 'T-0001');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.restarts, ['board-main']);
    expect(await local.current(), isNull);
    expect(() => local.backToMain(), throwsA(isA<InvalidInputException>()));
  });

  test('a server not started for the recorded preview does not run it', () async {
    await configure('{server: board-preview}');
    await preview();
    final local = LocalPreview(store: FilePreviewStore(stateDir), server: server); // not restarted
    expect(await local.current(), isNull);
    expect(await FilePreviewStore(stateDir).read(), isNotNull, reason: 'it may be another server\'s');
  });

  test('a folder that is not the helper worktree is never checked out by force', () async {
    // Someone's worktree with a branch and uncommitted work where the preview's should be.
    await git(path('repo'), ['worktree', 'add', '-q', '-b', 'mine', path('repo-preview')]);
    File(path('repo-preview/work.txt')).writeAsStringSync('unsaved\n');
    await git(path('repo-preview'), ['add', 'work.txt']);
    var result = await preview();
    expect(result.ok, isFalse);
    expect(result.summary, contains('is not the preview\'s helper worktree: it has the branch mine checked out'));
    expect(await git(path('repo-preview'), ['rev-parse', '--abbrev-ref', 'HEAD']), 'mine');
    expect(await git(path('repo-preview'), ['status', '--porcelain']), 'A  work.txt');

    await git(path('repo'), ['worktree', 'remove', '--force', path('repo-preview')]);
    Directory(path('repo-preview')).createSync();
    result = await preview();
    expect(result.summary, contains('it is not a worktree of'));
    expect(await FilePreviewStore(stateDir).read(), isNull);
  });

  test('dispatcher.preview is validated', () async {
    for (final (yaml, message) in [
      ('{colour: red}', 'unknown key "dispatcher.preview.colour"'),
      ('{worktree: "a/b"}', 'not a folder name'),
      ('{check: "make {nope}"}', 'unknown placeholder "{nope}"'),
      ('{worktree: "{repo}"}', 'must not be the primary clone itself'),
      ('{worktree: wt-1}', 'names a worktree of the dispatcher'),
      ('{worktree: "{repo}-2"}', 'names a worktree of the dispatcher'),
    ]) {
      await expectLater(
        configure(yaml),
        throwsA(isA<ConfigurationException>().having((e) => e.message, 'message', contains(message))),
      );
    }
  });
}

final class _FakeServer implements ServerControl {
  @override
  String program = 'board-main';
  @override
  String? preview;
  String? problem;
  final restarts = <String>[];

  @override
  Future<String?> problemWith(String program) async => problem;

  @override
  Future<void> restart(String program, {String? preview}) async => restarts.add(program);
}
