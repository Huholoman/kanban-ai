import 'dart:convert';
import 'dart:io';

import 'package:backlog_cli/backlog_cli.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class Run {
  Run(this.exitCode, this.out, this.err);

  final int exitCode;
  final String out;
  final String err;

  Object? get json => jsonDecode(out);

  @override
  String toString() => 'exit $exitCode\n$out$err';
}

void main() {
  late Directory workspace;
  late String backlogDir;
  final clock = FixedClock(DateTime.utc(2026, 10, 29, 12));

  Future<Run> backlog(List<String> args, {String? cwd, Map<String, String> env = const {}}) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runBacklogCli(
      args,
      CliContext(out: out, err: err, cwd: cwd ?? workspace.path, environment: env, clock: clock),
    );
    return Run(code, out.toString(), err.toString());
  }

  Future<String> create(String title, [List<String> options = const []]) async {
    final run = await backlog(['--json', 'new', title, ...options]);
    expect(run.exitCode, 0, reason: '$run');
    return (run.json! as Map)['id'] as String;
  }

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('backlog_cli_');
    backlogDir = p.join(workspace.path, 'backlog');
    expect((await backlog(['init', 'backlog', '--prefix', 'HB'])).exitCode, 0);
  });

  tearDown(() => workspace.delete(recursive: true));

  test('finds the backlog from a sibling worktree folder', () async {
    final worktree = await Directory(p.join(workspace.path, 'monorepo-2', 'lib')).create(recursive: true);
    final id = await create('Zürich DB backups', ['-p', 'p0', '-s', 'todo', '-m', 'launch', '-l', 'infra,db']);
    expect(id, matches(RegExp(r'^HB-[a-z0-9]{4}$')));

    final run = await backlog(['list'], cwd: worktree.path);
    expect(run.exitCode, 0);
    expect(run.out, contains('$id  p0  todo  Zürich DB backups  [launch] #infra #db'));
    expect(File(p.join(backlogDir, 'items', '$id-zurich-db-backups.md')).existsSync(), isTrue);
  });

  test('a full agent session: next, heartbeat, set, done unblocks the dependent', () async {
    final first = await create('First', ['-s', 'todo', '-p', 'p1']);
    final second = await create('Second', ['-s', 'todo', '-p', 'p0', '-d', first]);

    final ready = await backlog(['--json', 'ready']);
    expect((ready.json! as List).map((i) => (i as Map)['id']), [first]);

    final env = {'BACKLOG_AGENT': 'monorepo-3'};
    final next = await backlog(['--json', 'next'], env: env);
    expect(next.exitCode, 0, reason: '$next');
    final claimed = next.json! as Map;
    expect(claimed['id'], first);
    expect(claimed['status'], 'in-progress');
    expect((claimed['claim'] as Map)['agent'], 'monorepo-3');
    expect(claimed['path'], endsWith('.md'));

    expect((await backlog(['next'], env: env)).exitCode, ExitCode.nothingToDo);
    expect((await backlog(['heartbeat', first], env: env)).exitCode, 0);
    expect((await backlog(['set', first, 'branch=feat/first', 'labels+=infra'])).exitCode, 0);
    expect((await backlog(['claim', first, '--as', 'intruder'])).exitCode, ExitCode.conflict);

    final done = await backlog(['done', first], env: env);
    expect(done.exitCode, 0, reason: '$done');
    expect(done.out, contains('Now ready: $second'));

    final shown = (await backlog(['--json', 'show', first])).json! as Map;
    expect(shown['status'], 'done');
    expect(shown['branch'], 'feat/first');
    expect(shown['labels'], ['infra']);
    expect(shown['claim'], isNull);
  });

  test('show prints relations, claim and body', () async {
    final epic = await create('Data security', ['-t', 'epic']);
    final task = await create('Disk encryption in production', [
      '--parent',
      epic,
      '-s',
      'todo',
      '--body',
      '## Plan\n- [x] a\n- [ ] b',
    ]);
    await backlog(['claim', task, '--as', 'm4']);

    final epicView = await backlog(['show', epic]);
    expect(epicView.out, contains('child: $task Disk encryption in production (in-progress)'));

    final taskView = await backlog(['show', task.substring(3)]);
    expect(taskView.out, contains('parent: $epic Data security'));
    expect(taskView.out, contains('claim: m4 until'));
    expect(taskView.out, contains('checklist: 1/2'));
    expect(taskView.out, contains('## Plan'));
  });

  test('list filters: default hides done, --where, --all', () async {
    final a = await create('A', ['-s', 'todo', '-l', 'ui']);
    final b = await create('B', ['-s', 'done']);
    final c = await create('C', ['-s', 'backlog', '-m', 'launch']);

    Future<List<Object?>> ids(List<String> args) async =>
        ((await backlog(['--json', 'list', ...args])).json! as List).map((i) => (i as Map)['id']).toList();

    expect(await ids([]), unorderedEquals([a, c]));
    expect(await ids(['--all']), unorderedEquals([a, b, c]));
    expect(await ids(['-w', 'labels=ui']), [a]);
    expect(await ids(['-w', 'milestone?']), [c]);
    expect(await ids(['-w', 'status!=todo', '--all']), unorderedEquals([b, c]));
    expect(await ids(['-s', 'done']), [b]);
    expect(await ids(['-w', 'title~a', '--all']), [a]);
  });

  test('views: list, kanban and json groups', () async {
    await create('Doing', ['-s', 'in-progress', '-p', 'p0']);
    await create('Waiting', ['-s', 'todo']);

    final views = await backlog(['view']);
    expect(views.out, contains('board'));
    expect(views.out, contains('(kanban)'));

    final board = await backlog(['view', 'board']);
    expect(board.out, contains('== todo (1) =='));
    expect(board.out, contains('== in-progress (1) =='));

    final hot = (await backlog(['--json', 'view', 'hot'])).json! as Map;
    expect(hot['layout'], 'list');
    expect(((hot['groups'] as List).single as Map)['items'], hasLength(1));

    expect((await backlog(['view', 'nope'])).exitCode, ExitCode.notFound);
  });

  test('lint exits 1 on errors and reports them as JSON', () async {
    final id = await create('Valid');
    expect((await backlog(['lint'])).out, contains('All good.'));

    File(
      p.join(backlogDir, 'items', 'HB-zzzz-x.md'),
    ).writeAsStringSync('---\nid: HB-zzzz\ntitle: X\ndepends_on: [$id, HB-gone]\n---\n');
    final run = await backlog(['--json', 'lint']);
    expect(run.exitCode, 1);
    expect((run.json! as List).map((i) => (i as Map)['code']), contains('dangling-reference'));
  });

  test('errors: usage, unknown item, ambiguous reference, invalid value', () async {
    await create('One');
    await create('Two');

    expect((await backlog(['claim', 'x'])).exitCode, ExitCode.usage); // no agent
    expect((await backlog(['set', 'x'])).exitCode, ExitCode.usage);

    final missing = await backlog(['--json', 'show', 'nothing-like-this']);
    expect(missing.exitCode, ExitCode.notFound);
    expect(((missing.json! as Map)['error'] as Map)['type'], 'not_found');

    final ambiguous = await backlog(['show', 'HB']);
    expect(ambiguous.exitCode, ExitCode.notFound);
    expect(ambiguous.err, contains('matches 2 items'));

    final invalid = await backlog(['new', 'Bad', '-p', 'p9']);
    expect(invalid.exitCode, ExitCode.failure);
    expect(invalid.err, contains('Unknown priority "p9"'));
  });

  test('outside any backlog the error says how to fix it', () async {
    final elsewhere = await Directory.systemTemp.createTemp('backlog_elsewhere_');
    addTearDown(() => elsewhere.delete(recursive: true));
    final run = await backlog(['list'], cwd: elsewhere.path);
    expect(run.exitCode, ExitCode.notFound);
    expect(run.err, contains('backlog init'));
    expect((await backlog(['--dir', backlogDir, 'list'], cwd: elsewhere.path)).exitCode, 0);
  });

  test('instructions are available for agents', () async {
    final run = await backlog(['instructions']);
    expect(run.out, contains('backlog next'));
    expect(run.out, contains('BACKLOG_AGENT'));
  });
}
