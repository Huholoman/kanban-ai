import 'dart:convert';
import 'dart:io';

import 'package:backlog_cli/backlog_cli.dart';
import 'package:backlog_cli/src/render/text_output.dart';
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

  test('epic checks an epic and hands out its items one by one on its branch', () async {
    final epic = await create('Payments', ['-t', 'epic']);
    final first = await create('Model', ['--parent', epic, '-s', 'todo']);
    final second = await create('API', ['--parent', epic, '-d', first]);
    final outside = await create('Outside', ['-s', 'backlog']);

    final check = await backlog(['--json', 'epic', epic]);
    expect(check.exitCode, 0, reason: '$check');
    final plan = check.json! as Map;
    expect(plan['verdict'], 'ok');
    expect(plan['branch'], 'agent/$epic');
    expect(plan['next'], first);
    expect((plan['members'] as List).map((m) => (m as Map)['id']), [first, second]);
    expect(((plan['members'] as List)[1] as Map)['after'], [first]);

    final env = {'BACKLOG_AGENT': 'w1'};
    final next = await backlog(['epic', epic, '--next'], env: env);
    expect(next.exitCode, 0, reason: '$next');
    expect(next.out, contains('Claimed $first for w1, on the branch agent/$epic of $epic.'));
    expect((await backlog(['set', first, 'status=review'])).exitCode, 0);

    final again = (await backlog(['--json', 'epic', epic, '--next'], env: env)).json! as Map;
    expect((again['item'] as Map)['id'], second);
    expect((again['item'] as Map)['branch'], 'agent/$epic');
    expect((await backlog(['set', second, 'status=review'])).exitCode, 0);

    final none = await backlog(['epic', epic, '--next'], env: env);
    expect(none.exitCode, ExitCode.nothingToDo);
    expect(none.out, contains('Nothing left in $epic: every item is handed over or done.'));

    expect((await backlog(['set', epic, 'depends_on+=$outside'])).exitCode, 0);
    final text = await backlog(['epic', epic]);
    expect(text.out, contains('Cannot start:'));
    expect(text.out, contains('✗ Nothing left to implement'));
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

  test('times: UTC in the file and JSON, local time in show; a day from an older file stays', () async {
    final id = await create('Payments');
    final json = (await backlog(['--json', 'show', id])).json! as Map;
    expect(json['created'], '2026-10-29T12:00:00Z');
    expect(json['created_at'], '2026-10-29T12:00:00.000Z');
    expect(json['updated_at'], '2026-10-29T12:00:00.000Z');
    expect((await backlog(['show', id])).out, contains('created: ${TextOutput.time(DateTime.utc(2026, 10, 29, 12))}'));

    expect((await backlog(['set', id, 'created=2026-10-01'])).exitCode, 0);
    final old = (await backlog(['--json', 'show', id])).json! as Map;
    expect(old['created'], '2026-10-01');
    expect(old['created_at'], isNull);
    expect((await backlog(['show', id])).out, contains('created: 2026-10-01 '));
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
    expect(run.out, contains('backlog check T-7f3a'));
  });

  test('check and uncheck tick checklist items by number or text and keep the file as it was', () async {
    final id = await create('Export', ['--body', '## Checklist\n\n- [ ] CSV export\n- [ ] JSON export # later\n']);
    final file = File(p.join(backlogDir, 'items', '$id-export.md'));
    file.writeAsStringSync(file.readAsStringSync().replaceFirst('title:', '# hand comment\ntitle:'));
    final before = file.readAsStringSync();

    final listed = await backlog(['check', id]);
    expect(listed.out, 'Checklist of $id (0/2):\n  1. [ ] CSV export\n  2. [ ] JSON export # later\n');

    final byText = await backlog(['check', id, 'csv', 'EXPORT']);
    expect(byText.exitCode, 0, reason: '$byText');
    expect(byText.out, startsWith('Checked 1 on $id.\nChecklist of $id (1/2):\n  1. [x] CSV export\n'));
    expect(file.readAsStringSync(), before.replaceFirst('- [ ] CSV', '- [x] CSV'));

    final json = await backlog(['--json', 'check', id, '1', '2']);
    expect((json.json! as Map)['changed'], [2]);
    expect((json.json! as Map)['progress'], {'done': 2, 'total': 2});
    expect((json.json! as Map)['checklist'], [
      {'number': 1, 'text': 'CSV export', 'done': true},
      {'number': 2, 'text': 'JSON export # later', 'done': true},
    ]);
    expect((await backlog(['check', id, '2'])).out, startsWith('2 was checked already.\n'));

    expect((await backlog(['uncheck', id, '2'])).out, startsWith('Unchecked 2 on $id.\n'));
    expect(file.readAsStringSync(), before.replaceFirst('- [ ] CSV', '- [x] CSV'));
    final show = await backlog(['--json', 'show', id]);
    expect(((show.json! as Map)['checklist'] as List).map((e) => (e as Map)['done']), [true, false]);

    expect((await backlog(['check', id, '3'])).exitCode, ExitCode.notFound);
    expect((await backlog(['check', id, 'export'])).err, contains('matches 2 checklist items'));
    expect((await backlog(['check', await create('Empty'), '1'])).err, contains('has no checklist'));
    expect((await backlog(['check'])).exitCode, ExitCode.usage);
  });

  test('history: text and JSON, filters, runs from the logs of a registered project', () async {
    final env = {
      'HOME': p.join(workspace.path, 'home'),
      'XDG_CONFIG_HOME': p.join(workspace.path, 'config'),
      'KANBAN_AI_STATE_DIR': p.join(workspace.path, 'state'),
    };
    final id = await create('Payments', ['-s', 'todo']);
    expect((await backlog(['ask', id, 'CSV or JSON?', '--as', 'm2'])).exitCode, 0);
    final added = await backlog(['--json', 'projects', 'add'], env: env);
    expect(added.exitCode, 0, reason: '$added');
    final project = (added.json! as Map)['id'] as String;
    final logs = await Directory(p.join(workspace.path, 'state', 'logs', project)).create(recursive: true);
    File(p.join(logs.path, '$id-20261029T130000Z.log')).writeAsStringSync(
      '# kanban-ai: claude for $id in wt-1 (/w), branch agent/$id, started 2026-10-29T13:00:00.000Z\n'
      '# kanban-ai: the agent exited with code 0; $id stays todo\n',
    );

    final text = await backlog(['history', id], env: env);
    expect(text.exitCode, 0, reason: '$text');
    expect(text.out, contains('created (todo)'));
    expect(text.out, contains('m2'));
    expect(text.out, contains('question: CSV or JSON?'));
    expect(text.out, contains('wt-1  agent: claude for $id'));

    final json = (await backlog(['--json', 'history', id, '--only', 'runs'], env: env)).json! as List;
    expect(json.single, containsPair('kind', 'run'));
    expect(json.single, containsPair('at', '2026-10-29T13:00:00.000Z'));
    expect((await backlog(['--json', 'history', id, '--only', 'comments'])).json, [containsPair('author', 'm2')]);
    expect((await backlog(['history', id, '--only', 'nope'])).exitCode, ExitCode.usage);
  });

  test('projects: add the backlog found here or a given one, list, pin, remove', () async {
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

    expect((await backlog(['projects', 'pin', 'tools'], env: env)).out, contains('Pinned tools.'));
    expect(File(registry).readAsStringSync(), contains('pinned: true'));
    expect((await backlog(['projects', 'pin', 'nope'], env: env)).exitCode, ExitCode.notFound);

    await Directory(other).rename('$other-moved');
    final listed = await backlog(['--json', 'projects'], env: env);
    expect(listed.json, [
      {
        'id': ProjectRegistry.deriveId(backlogDir),
        'name': project,
        'path': backlogDir,
        'default': true,
        'pinned': false,
        'error': null,
      },
      {
        'id': 'tools',
        'name': 'Tools',
        'path': other,
        'default': false,
        'pinned': true,
        'error': 'Folder $other does not exist.',
      },
    ]);
    final text = await backlog(['projects'], env: env);
    expect(text.out, contains('(default)'));
    expect(text.out, contains('(pinned)'));
    final unpinned = await backlog(['--json', 'projects', 'unpin', 'tools'], env: env);
    expect((unpinned.json! as Map)['pinned'], isFalse);
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

  group('init presets', () {
    late Map<String, String> env;
    late String userPresets;

    setUp(() {
      env = {'XDG_CONFIG_HOME': p.join(workspace.path, 'config'), 'HOME': p.join(workspace.path, 'home')};
      userPresets = p.join(workspace.path, 'config', 'kanban-ai', 'presets');
    });

    Future<Run> init(List<String> args) => backlog(['init', '--no-register', ...args], env: env);
    String read(String path) => File(p.join(workspace.path, path)).readAsStringSync();

    test('--list-presets names the built-in ones and the user\'s', () async {
      final builtIn = await init(['--list-presets']);
      expect(builtIn.exitCode, 0);
      expect(builtIn.out.split('\n').map((line) => line.split(' ').first), [
        'default',
        'minimal',
        'agents',
        'agents-review',
        '',
      ]);

      Directory(p.join(userPresets, 'shop', 'views')).createSync(recursive: true);
      File(p.join(userPresets, 'shop', 'backlog.yaml')).writeAsStringSync('id: {prefix: SHOP}\n');
      File(p.join(userPresets, 'shop', 'preset.yaml')).writeAsStringSync('description: Our shop projects\n');
      final listed = await backlog(['--json', 'init', '--list-presets'], env: env);
      expect((listed.json! as List).last, {
        'name': 'shop',
        'description': 'Our shop projects',
        'source': p.join(userPresets, 'shop'),
        'agents_guide': false,
      });
      expect(Directory(p.join(workspace.path, 'views')).existsSync(), isFalse, reason: 'listing creates nothing');
    });

    test('without a preset init writes the default template, as before', () async {
      expect((await init(['plain', '--prefix', 'PL'])).out, startsWith('Created backlog in '));
      expect(read('plain/backlog.yaml'), startsWith('# Backlog configuration. Items live in items/'));
      expect(read('plain/backlog.yaml'), contains('  prefix: PL      # new items get ids like PL-7f3a\n'));
      expect(read('plain/backlog.yaml'), contains('# dispatcher:\n'));
      expect(Directory(p.join(workspace.path, 'plain', 'views')).listSync().map((f) => p.basename(f.path)).toSet(), {
        for (final id in builtInPresets.first.views.keys) '$id.yaml',
      });
    });

    test('minimal: three statuses, no dispatcher; the backlog lints clean', () async {
      final run = await init(['todo', '--preset', 'minimal', '--prefix', 'TD']);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.out, contains('from preset minimal (ids TD-…)'));
      expect(run.out, isNot(contains('CLAUDE.md')));
      final opened = await Backlog.open(p.join(workspace.path, 'todo'));
      expect(opened.workflow.statuses.map((s) => s.id), ['todo', 'in-progress', 'done']);
      expect(opened.workflow.dispatcher, isNull);
      expect((await opened.linter.run()).where((issue) => issue.severity == Severity.error), isEmpty);
    });

    test('agents: dispatcher for the repository, milestones, and the guide printed or appended', () async {
      Directory(p.join(workspace.path, 'app')).createSync();
      final run = await init(['app/backlog', '--preset', 'agents', '--prefix', 'AP']);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.out, contains('Add this guide for agents to CLAUDE.md / AGENTS.md'));
      expect(run.out, contains('Work on app is planned in a kanban-ai backlog (Markdown files, ids\n`AP-…`)'));
      final opened = await Backlog.open(p.join(workspace.path, 'app', 'backlog'));
      expect(opened.workflow.milestones.map((m) => m.id), ['v0.1', 'later']);
      expect(opened.workflow.dispatcher!.mode, DispatchMode.manual);
      expect(read('app/backlog/backlog.yaml'), contains('repo: ..        #'));
      expect(read('app/backlog/backlog.yaml'), contains('worktree_name: "app-agent-{n}"'));
      expect((await opened.linter.run()).where((issue) => issue.severity == Severity.error), isEmpty);

      final claude = p.join(workspace.path, 'repo', 'CLAUDE.md');
      File(claude)
        ..createSync(recursive: true)
        ..writeAsStringSync('# Repo rules\n');
      final reviewed = await backlog([
        '--json',
        'init',
        'other',
        '--no-register',
        '--preset',
        'agents-review',
        '--repo',
        'repo',
        '--agents-file',
        claude,
      ], env: env);
      expect(reviewed.exitCode, 0, reason: '$reviewed');
      expect((reviewed.json! as Map)['agents_file'], claude);
      expect((reviewed.json! as Map)['prefix'], 'T');
      expect(read('repo/CLAUDE.md'), startsWith('# Repo rules\n\n## Backlog\n'));
      expect(read('other/backlog.yaml'), contains('repo: ../repo'));
      expect(read('other/backlog.yaml'), contains('worktree_name: "repo-agent-{n}"'));
      expect((await Backlog.open(p.join(workspace.path, 'other'))).workflow.dispatcher!.actions.map((a) => a.name), [
        'AI review',
        'Merge',
      ]);
      final again = await init(['third', '--preset', 'agents', '--agents-file', claude]);
      expect(again.out, contains('has the guide for agents already'));
      expect('## Backlog'.allMatches(read('repo/CLAUDE.md')), hasLength(1));
    });

    test(
      'a preset folder or a user preset by name, with placeholders; --from copies a backlog without items',
      () async {
        final folder = Directory(p.join(workspace.path, 'presets', 'mine'))..createSync(recursive: true);
        File(p.join(folder.path, 'backlog.yaml')).writeAsStringSync(r'''
# ${project} backlog
id:
  prefix: ${prefix}
statuses: [{id: open, category: open, pickable: true}, {id: doing, category: active}, {id: closed, category: done}]
''');
        File(p.join(folder.path, 'AGENTS.md')).writeAsStringSync(
          r'Ids are ${prefix}-xxxx; keep ${unknown}.'
          '\n',
        );
        final run = await init(['made', '--preset', './presets/mine', '--prefix', 'MD']);
        expect(run.exitCode, 0, reason: '$run');
        expect(read('made/backlog.yaml'), startsWith('# made backlog\nid:\n  prefix: MD\n'));
        expect(
          run.out,
          endsWith(
            r'Ids are MD-xxxx; keep ${unknown}.'
            '\n',
          ),
        );
        expect(
          Directory(p.join(workspace.path, 'made', 'views')).listSync(),
          hasLength(builtInPresets.first.views.length),
          reason: 'no views/: the default ones',
        );

        Directory(userPresets).createSync(recursive: true);
        folder.renameSync(p.join(userPresets, 'mine'));
        expect((await init(['by-name', '--preset', 'mine'])).out, contains('(ids T-…)'));
        expect(
          (await init(['nope', '--preset', 'nope'])).err,
          contains('No preset "nope"; there are default, minimal'),
        );

        await create('Not copied');
        final copied = await init(['copy', '--from', '.', '--prefix', 'CP']);
        expect(copied.out, contains('from the backlog $backlogDir (ids CP-…)'));
        expect(
          read('copy/backlog.yaml'),
          File(p.join(backlogDir, 'backlog.yaml')).readAsStringSync().replaceFirst('HB', 'CP'),
        );
        expect(Directory(p.join(workspace.path, 'copy', 'items')).listSync().map((f) => p.basename(f.path)), [
          '.gitkeep',
        ]);
        expect((await init(['kept', '--from', 'backlog'])).out, contains('(ids HB-…)'));
        expect((await init(['x', '--from', 'backlog', '--preset', 'minimal'])).exitCode, ExitCode.usage);
      },
    );
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
        'review': null,
        'commit': null,
      },
      {
        'author': 'tobik',
        'at': '2026-10-29T12:00:00.000Z',
        'text': 'CSV.\nWith a header.',
        'question': false,
        'note': false,
        'review': null,
        'commit': null,
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

  test('comment and ask --file take a long, multi-line text from a file', () async {
    final id = await create('Export', ['-s', 'todo']);
    final agent = {'BACKLOG_AGENT': 'monorepo-2'};
    File(p.join(workspace.path, 'question.md')).writeAsStringSync('Two options:\n\n1. CSV\n2. JSON\n');
    final asked = await backlog(['ask', id, '--file', 'question.md'], env: agent);
    expect(asked.exitCode, 0, reason: '$asked');
    final json = (await backlog(['--json', 'show', id])).json! as Map;
    expect((json['discussion'] as List).last, containsPair('text', 'Two options:\n\n1. CSV\n2. JSON'));
    expect(json['needs_human'], isTrue);

    final both = await backlog(['comment', id, 'x', '--file', 'question.md'], env: agent);
    expect(both.exitCode, ExitCode.usage, reason: 'the text or --file');
    final missing = await backlog(['comment', id, '-F', 'nope.md'], env: agent);
    expect(missing.exitCode, isNot(0));
    expect(missing.err, contains('Cannot read'));
    expect((await backlog(['comment', id, '--file', '-'], env: agent, input: 'From stdin.')).exitCode, 0);
  });

  test('describe replaces the description or one section; the discussion stays', () async {
    final id = await create('Export', ['-s', 'todo', '--body', 'Old.\n\n## Acceptance criteria\n\n- old']);
    await backlog(['ask', id, 'CSV?'], env: {'BACKLOG_AGENT': 'monorepo-2'});
    File(p.join(workspace.path, 'criteria.md')).writeAsStringSync('- CSV with a header\n- UTF-8\n');
    final section = await backlog(['describe', id, '--section', 'Acceptance criteria', '--file', 'criteria.md']);
    expect(section.exitCode, 0, reason: '$section');
    expect(section.out, contains('Replaced the section "Acceptance criteria" of $id.'));
    final path = (await backlog(['path', id])).out.trim();
    expect(
      File(path).readAsStringSync(),
      endsWith(
        '\nOld.\n\n## Acceptance criteria\n\n- CSV with a header\n- UTF-8\n\n## Discussion\n\n'
        '### monorepo-2 · 2026-10-29 12:00:00 UTC · question\n\nCSV?\n',
      ),
    );

    expect((await backlog(['describe', id, 'Export', 'it', 'as', 'CSV.'])).exitCode, 0);
    final json = (await backlog(['--json', 'show', id])).json! as Map;
    expect(json['body'], startsWith('Export it as CSV.\n\n## Discussion\n'));
    expect(json['needs_human'], isTrue, reason: 'the open question stays');
    expect((await backlog(['describe', id, '--section', 'Discussion', 'x'])).exitCode, isNot(0));
    expect((await backlog(['describe', id])).exitCode, ExitCode.usage);
    final shown = (await backlog(['show', id])).out;
    final withDiscussion = await backlog(['describe', id, '--file', '-'], input: 'New.\n\n## Discussion\n\nx\n');
    expect(withDiscussion.exitCode, isNot(0));
    expect(withDiscussion.err, contains('## Discussion'));
    expect(
      (await backlog(['describe', id, '-s', 'Plan', '--file', '-'], input: 'a\n\n## Discussion\n')).exitCode,
      isNot(0),
    );
    expect((await backlog(['show', id])).out, shown, reason: 'a rejected text changes nothing');
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

  test('action lists what an item offers and leaves a request for the server', () async {
    final config = File(p.join(backlogDir, 'backlog.yaml'));
    config.writeAsStringSync(
      '${config.readAsStringSync()}\n'
      'dispatcher:\n'
      '  worktrees: [w1]\n'
      '  actions:\n'
      '    - {name: AI review, on_enter: review, prompt: "Review {id}"}\n'
      '    - {name: Tests, statuses: [review], run: [sh, -c, "true"]}\n'
      '    - {name: Noop, run: noop}\n',
    );
    final id = await create('Export', ['-s', 'review']);
    final listed = await backlog(['action', id]);
    expect(listed.exitCode, 0, reason: '$listed');
    expect(listed.out.split('\n'), [
      'AI review  —  agent; runs on entering review',
      'Tests  —  run: sh -c true',
      'Noop  —  run: noop',
      '',
    ]);
    final todo = await create('Other', ['-s', 'todo']);
    expect((await backlog(['action', todo])).out, contains('(AI review runs by itself on entering review)'));
    expect(((await backlog(['--json', 'action', todo])).json! as List).first, {
      'name': 'AI review',
      'kind': 'prompt',
      'offered': false,
      'on_enter': 'review',
      'statuses': null,
      'agent': 'claude',
      'fresh': false,
      'review': false,
      'auto_fix': 0,
    });

    final requested = await backlog(['action', id, 'Tests'], env: {'USER': 'tobik'});
    expect(requested.exitCode, 0, reason: '$requested');
    expect(requested.out, contains('Requested "Tests" for $id. A running backlog-server'));
    final requests = await (await Backlog.open(backlogDir)).actionRequests.take();
    expect(requests.map((r) => (r.item, r.action, r.by)), [(id, 'Tests', 'tobik')]);

    expect((await backlog(['action', todo, 'Tests'])).err, contains('not offered for items in todo'));
    expect((await backlog(['action', id, 'Nope'])).exitCode, 4);
  });
}
