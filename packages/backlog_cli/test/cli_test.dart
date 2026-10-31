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

  Future<Run> backlog(List<String> args, {String? cwd, Map<String, String> env = const {}, String? input}) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runBacklogCli(
      args,
      CliContext(
        out: out,
        err: err,
        cwd: cwd ?? workspace.path,
        environment: env,
        clock: clock,
        readInput: input == null ? null : () async => input,
      ),
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

  test('touches: new, set, show and JSON', () async {
    final id = await create('Payments', ['--touches', 'lib/payments/', '--touches', 'lib/*.{dart,yaml},docs/']);
    final json = (await backlog(['--json', 'show', id])).json! as Map;
    expect(json['touches'], ['lib/payments/', 'lib/*.{dart,yaml}', 'docs/']);
    expect((await backlog(['set', id, 'touches-=docs/'])).exitCode, 0);
    expect((await backlog(['show', id])).out, contains('touches: lib/payments/, lib/*.{dart,yaml}\n'));
  });

  test('an item overlapping work in progress waits: list, ready, show, JSON', () async {
    final doing = await create('Payments', ['-s', 'in-progress', '--touches', 'lib/pay/']);
    final waiting = await create('Stripe', ['-s', 'todo', '--touches', 'lib/pay/stripe.dart']);
    final free = await create('Orders', ['-s', 'todo', '--touches', 'lib/orders/']);

    expect((await backlog(['list'])).out, contains('waits for $doing (touches overlap)'));
    final ready = ((await backlog(['--json', 'ready'])).json! as List).map((i) => (i as Map)['id']);
    expect(ready, [free]);
    final json = (await backlog(['--json', 'show', waiting])).json! as Map;
    expect(json['conflicting'], isTrue);
    expect(json['conflicts_with'], [doing]);
    expect(json['ready'], isFalse);
    expect(
      (await backlog(['show', waiting])).out,
      contains('waits for: $doing Payments (in-progress), touches overlap'),
    );
    expect((await backlog(['show', doing])).out, contains('holds up: $waiting Stripe (todo)'));
    final listed = ((await backlog(['--json', 'list', '-w', 'conflicting=true'])).json! as List).map(
      (i) => (i as Map)['id'],
    );
    expect(listed, [waiting]);
    expect((await backlog(['claim', waiting, '--as', 'm2'])).exitCode, isNot(0));
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

  test('projects: add the backlog found here or a given one, list, remove', () async {
    final env = {'HOME': p.join(workspace.path, 'home'), 'XDG_CONFIG_HOME': p.join(workspace.path, 'config')};
    final registry = p.join(workspace.path, 'config', 'kanban-ai', 'projects.yaml');
    final worktree = await Directory(p.join(workspace.path, 'repo-2')).create();

    final empty = await backlog(['projects'], env: env);
    expect(empty.out, contains('No projects in $registry'));

    final added = await backlog(['--json', 'projects', 'add'], cwd: worktree.path, env: env);
    expect(added.exitCode, 0, reason: '$added');
    final project = p.basename(workspace.path);
    expect((added.json! as Map)['path'], backlogDir);
    expect((added.json! as Map)['id'], ProjectRegistry.deriveId(backlogDir));

    final other = p.join(workspace.path, 'other');
    expect((await backlog(['init', other])).exitCode, 0);
    final named = await backlog(['projects', 'add', 'other', '--id', 'tools', '--name', 'Tools'], env: env);
    expect(named.out, contains('Added tools ($other)'));

    final missing = await backlog(['projects', 'add', 'nowhere'], env: env);
    expect(missing.exitCode, ExitCode.notFound);
    final twice = await backlog(['projects', 'add', other], env: env);
    expect(twice.exitCode, ExitCode.failure);
    expect(twice.err, contains('already registered as "tools"'));

    await Directory(other).rename('$other-moved');
    final listed = await backlog(['--json', 'projects'], env: env);
    expect(listed.json, [
      {'id': ProjectRegistry.deriveId(backlogDir), 'name': project, 'path': backlogDir, 'default': true, 'error': null},
      {'id': 'tools', 'name': 'Tools', 'path': other, 'default': false, 'error': 'Folder $other does not exist.'},
    ]);
    final text = await backlog(['projects'], env: env);
    expect(text.out, contains('(default)'));
    expect(text.out, contains('error: Folder $other does not exist.'));

    expect((await backlog(['projects', 'remove', 'tools'], env: env)).out, contains('Removed tools'));
    expect((await backlog(['projects', 'remove', 'tools'], env: env)).exitCode, ExitCode.notFound);
    expect((await backlog(['projects', 'remove'], env: env)).exitCode, ExitCode.usage);
    expect((await backlog(['projects', '--id', 'x'], env: env)).exitCode, ExitCode.usage);

    final explicit = p.join(workspace.path, 'elsewhere.yaml');
    expect((await backlog(['projects', 'add', '--projects', explicit], env: env)).exitCode, 0);
    expect(File(explicit).readAsStringSync(), contains('path: $backlogDir'));
    expect((await backlog(['projects'], env: {...env, 'BACKLOG_PROJECTS': explicit})).out, contains(backlogDir));
  });

  test('init registers the new backlog unless told not to', () async {
    final env = {'XDG_CONFIG_HOME': p.join(workspace.path, 'config')};
    final registry = p.join(workspace.path, 'config', 'kanban-ai', 'projects.yaml');
    final created = await backlog(['init', 'shop/backlog'], env: env);
    expect(created.out, contains('Registered as project shop in $registry'));
    final json = await backlog(['--json', 'init', 'tools'], env: env);
    expect((json.json! as Map)['project'], {'id': 'tools', 'name': 'tools'});
    expect((await backlog(['init', 'quiet', '--no-register'], env: env)).out, isNot(contains('Registered')));
    final listed = await backlog(['--json', 'projects'], env: env);
    expect((listed.json! as List).map((project) => (project as Map)['id']), ['shop', 'tools']);

    File(registry).writeAsStringSync('projects: {broken: true}');
    final warned = await backlog(['init', 'more'], env: env);
    expect(warned.exitCode, 0);
    expect(warned.err, contains('warning: not registered'));
  });

  test('comment and ask write the discussion; a question makes the item need a person', () async {
    final id = await create('Export', ['-s', 'todo', '--body', '## Context\n\nExport it.\n']);
    final agent = {'BACKLOG_AGENT': 'monorepo-2'};
    final asked = await backlog(['ask', id, 'CSV', 'or JSON?'], env: agent);
    expect(asked.exitCode, 0, reason: '$asked');
    expect(asked.out, contains('it waits for a person now'));
    expect(asked.out, contains('needs a person (question by monorepo-2)'));
    expect((await backlog(['--json', 'ready'])).json, isEmpty);
    expect((await backlog(['--json', 'list', '-w', 'needs_human=true'])).json, hasLength(1));
    expect((await backlog(['show', id])).out, contains('NEEDS A PERSON: monorepo-2 asked a question'));

    final answered = await backlog(['--json', 'comment', id, '-', '--as', 'tobik'], input: 'CSV.\nWith a header.\n');
    expect(answered.exitCode, 0, reason: '$answered');
    final json = answered.json! as Map;
    expect(json['needs_human'], isFalse);
    expect(json['ready'], isTrue);
    expect(json['discussion'], [
      {
        'author': 'monorepo-2',
        'at': '2026-10-29T12:00:00.000Z',
        'text': 'CSV or JSON?',
        'question': true,
        'note': false,
      },
      {
        'author': 'tobik',
        'at': '2026-10-29T12:00:00.000Z',
        'text': 'CSV.\nWith a header.',
        'question': false,
        'note': false,
      },
    ]);
    expect(
      File((json['path'] as String)).readAsStringSync(),
      endsWith(
        '## Context\n\nExport it.\n\n## Discussion\n\n'
        '### monorepo-2 · 2026-10-29 12:00:00 UTC · question\n\nCSV or JSON?\n\n'
        '### tobik · 2026-10-29 12:00:00 UTC\n\nCSV.\nWith a header.\n',
      ),
    );

    expect((await backlog(['comment', id, 'x'])).exitCode, ExitCode.usage, reason: 'no author');
    expect((await backlog(['ask', id, 'x', '--note'], env: agent)).exitCode, ExitCode.usage, reason: 'ask has no note');
    expect((await backlog(['comment', id], env: agent)).exitCode, ExitCode.usage, reason: 'no text');
    expect((await backlog(['comment', id, 'x'], env: {'USER': 'tobik'})).exitCode, 0);
  });

  test('comment --note keeps an open question open', () async {
    final id = await create('Export', ['-s', 'todo']);
    await backlog(['ask', id, 'CSV or JSON?'], env: {'BACKLOG_AGENT': 'monorepo-2'});
    final noted = await backlog(['comment', id, '--note', 'Thinking.', '--as', 'tobik']);
    expect(noted.exitCode, 0, reason: '$noted');
    expect(noted.out, contains('does not wake its agent or answer a question'));
    expect(noted.out, contains('needs a person'));
    final json = (await backlog(['--json', 'show', id])).json! as Map;
    expect(json['needs_human'], isTrue);
    expect((json['discussion'] as List).last, containsPair('note', true));
    expect(File(json['path'] as String).readAsStringSync(), contains('### tobik · 2026-10-29 12:00:00 UTC · note\n'));
  });
}
