import 'dart:convert';
import 'dart:io';

import 'package:backlog_cli/backlog_cli.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `backlog pr` against a local bare repository as the remote and a fake
/// `create` command (a shell script that records its arguments and standard
/// input and prints a URL), the way `tea pulls create` or `gh pr create`
/// would be configured.
void main() {
  late Directory workspace;
  late String backlogDir, repo, remote, calls;
  final clock = FixedClock(DateTime.utc(2026, 10, 31, 12));

  Future<({int code, String out, String err})> backlog(List<String> args, {String? input}) async {
    final out = StringBuffer(), err = StringBuffer();
    final code = await runBacklogCli(
      args,
      CliContext(
        out: out,
        err: err,
        cwd: repo,
        environment: const {'BACKLOG_AGENT': 'repo'},
        clock: clock,
        readInput: input == null ? null : () async => input,
      ),
    );
    return (code: code, out: '$out', err: '$err');
  }

  Future<String> git(String dir, List<String> args) async {
    final result = await Process.run('git', [
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      ...args,
    ], workingDirectory: dir);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return '${result.stdout}'.trim();
  }

  Future<void> configure(String pr) async {
    final config = File(p.join(backlogDir, 'backlog.yaml'));
    await config.writeAsString(
      '${await config.readAsString()}\ndispatcher:\n  worktrees: [{name: repo, path: ../repo}]\n$pr',
    );
  }

  /// The fake `create`: records "args" and the standard input, prints [output].
  Future<String> script(String name, String output, {int exitCode = 0}) async {
    final file = File(p.join(workspace.path, name));
    await file.writeAsString(
      'printf "%s\\n" "\$*" >> "$calls"\n'
      'cat >> "$calls.stdin"\n'
      'printf "%s\\n" "$output"\n'
      'exit $exitCode\n',
    );
    return file.path;
  }

  Future<String> newItem(String title, {String? branch}) async {
    final run = await backlog([
      '--json',
      'new',
      title,
      '-s',
      'review',
      if (branch != null) ...['--branch', branch],
    ]);
    expect(run.code, 0, reason: run.err);
    return (jsonDecode(run.out) as Map)['id'] as String;
  }

  Future<Item> item(String id) async => (await Backlog.open(backlogDir)).items.get(id);

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('backlog_pr_');
    backlogDir = p.join(workspace.path, 'backlog');
    repo = p.join(workspace.path, 'repo');
    remote = p.join(workspace.path, 'remote.git');
    calls = p.join(workspace.path, 'calls');
    await git(workspace.path, ['init', '-q', '--bare', '-b', 'main', remote]);
    await git(workspace.path, ['init', '-q', '-b', 'main', repo]);
    await git(repo, ['commit', '-q', '--allow-empty', '-m', 'init']);
    await git(repo, ['remote', 'add', 'origin', remote]);
    await git(repo, ['push', '-q', 'origin', 'main']);
    await git(repo, ['switch', '-q', '-c', 'agent/work']);
    await git(repo, ['commit', '-q', '--allow-empty', '-m', 'Do the work']);
    final out = StringBuffer();
    expect(
      await runBacklogCli([
        'init',
        backlogDir,
        '--prefix',
        'PR',
        '--no-register',
      ], CliContext(out: out, err: out, cwd: workspace.path)),
      0,
      reason: '$out',
    );
  });

  tearDown(() => workspace.delete(recursive: true));

  test('pushes the item\'s branch, opens the pull request with the description on stdin, records the URL', () async {
    final create = await script('fake-tea.sh', 'Created PR #7 https://git.example/o/r/pulls/7');
    await configure('  pr:\n    create: [sh, $create, "--head", "{branch}", "--base", "{base}", "{id}: {title}"]\n');
    final id = await newItem('Export CSV', branch: 'agent/work');

    final run = await backlog(['--json', 'pr', id, '--description', 'Adds the export.\n\nVerified with the tests.']);
    expect(run.code, 0, reason: run.err);
    expect(jsonDecode(run.out), {
      'url': 'https://git.example/o/r/pulls/7',
      'created': true,
      'branch': 'agent/work',
      'base': 'main',
      'remote': 'origin',
    });
    expect((await item(id)).pr, 'https://git.example/o/r/pulls/7');
    expect(await git(remote, ['rev-parse', 'agent/work']), await git(repo, ['rev-parse', 'agent/work']));
    expect(await File(calls).readAsString(), '--head agent/work --base main $id: Export CSV\n');
    expect(
      await File('$calls.stdin').readAsString(),
      'Adds the export.\n\nVerified with the tests.\n\nBacklog item: $id',
      reason: 'a description that does not name the item gets a reference',
    );
  });

  test('is idempotent: with a pull request it only pushes the new commits', () async {
    final create = await script('fake-tea.sh', 'https://git.example/o/r/pulls/7');
    await configure('  pr:\n    create: [sh, $create]\n');
    final id = await newItem('Export CSV', branch: 'agent/work');
    expect((await backlog(['pr', id])).code, 0);

    await git(repo, ['commit', '-q', '--allow-empty', '-m', 'Review fixes']);
    final again = await backlog(['pr', id]);
    expect(again.code, 0, reason: again.err);
    expect(again.out, contains('the pull request exists: https://git.example/o/r/pulls/7'));
    expect((await File(calls).readAsLines()), hasLength(1), reason: 'create ran once');
    expect(await git(remote, ['log', '-1', '--format=%s', 'agent/work']), 'Review fixes');
  });

  test('without a description it writes one from the item and its commits; - reads stdin', () async {
    final create = await script('fake-gh.sh', 'https://github.com/o/r/pull/3');
    await configure('  pr:\n    create: \'sh $create --body-file -\'\n');
    final id = await newItem('Export CSV');

    // No branch field: the checked-out branch.
    expect((await backlog(['pr', id])).code, 0);
    expect(await File('$calls.stdin').readAsString(), 'Export CSV\n\nBacklog item: $id\n\nCommits:\n- Do the work');

    final other = await newItem('Second', branch: 'agent/work');
    expect((await backlog(['pr', other, '--description-file', '-'], input: 'For $other: details')).code, 0);
    expect(await File('$calls.stdin').readAsString(), endsWith('For $other: details'));
  });

  test('a pull request found by find is recorded instead of opening another', () async {
    final create = await script('fake-create.sh', 'https://git.example/o/r/pulls/9');
    final find = await script('fake-find.sh', 'index,head,url https://git.example/o/r/pulls/4');
    await configure('  pr:\n    create: [sh, $create]\n    find: [sh, $find, "{branch}"]\n');
    final id = await newItem('Export CSV', branch: 'agent/work');

    final run = await backlog(['--json', 'pr', id]);
    expect(run.code, 0, reason: run.err);
    expect((jsonDecode(run.out) as Map)['created'], isFalse);
    expect((await item(id)).pr, 'https://git.example/o/r/pulls/4');
    expect(await File(calls).readAsLines(), ['agent/work'], reason: 'only find ran');
  });

  test('after a rebase only --force (with a lease) replaces the remote branch', () async {
    final create = await script('fake-tea.sh', 'https://git.example/o/r/pulls/7');
    await configure('  pr:\n    create: [sh, $create]\n');
    final id = await newItem('Export CSV', branch: 'agent/work');
    expect((await backlog(['pr', id])).code, 0);

    await git(repo, ['switch', '-q', 'main']);
    await git(repo, ['commit', '-q', '--allow-empty', '-m', 'Meanwhile on main']);
    await git(repo, ['switch', '-q', 'agent/work']);
    await git(repo, ['rebase', '-q', 'main']);
    final plain = await backlog(['pr', id]);
    expect(plain.code, isNot(0));
    expect(plain.err, contains('backlog pr $id --force'));

    final forced = await backlog(['pr', id, '--force']);
    expect(forced.code, 0, reason: forced.err);
    expect(await git(remote, ['rev-parse', 'agent/work']), await git(repo, ['rev-parse', 'agent/work']));
    expect(await git(remote, ['log', '-1', '--format=%s', 'main']), 'init', reason: 'the base is never pushed');

    // Someone else pushed to the branch in the meantime: the lease refuses.
    final other = p.join(workspace.path, 'other');
    await git(workspace.path, ['clone', '-q', '-b', 'agent/work', remote, other]);
    await git(other, ['commit', '-q', '--allow-empty', '-m', 'Not seen here']);
    await git(other, ['push', '-q', 'origin', 'agent/work']);
    await git(repo, ['commit', '--amend', '-q', '--allow-empty', '-m', 'Rewritten']);
    expect((await backlog(['pr', id, '--force'])).code, isNot(0));
    expect(await git(remote, ['log', '-1', '--format=%s', 'agent/work']), 'Not seen here');
  });

  test('never pushes the base branch', () async {
    final create = await script('fake-tea.sh', 'https://git.example/o/r/pulls/7');
    await configure('  pr:\n    create: [sh, $create]\n');
    final id = await newItem('Sneaky', branch: 'main');
    await git(repo, ['switch', '-q', 'main']);
    await git(repo, ['commit', '-q', '--allow-empty', '-m', 'Straight to main']);

    final run = await backlog(['pr', id]);
    expect(run.code, 1);
    expect(run.err, contains('base branch main'));
    expect(await git(remote, ['log', '-1', '--format=%s', 'main']), 'init');
    expect(File(calls).existsSync(), isFalse);
  });

  test('failures: no dispatcher.pr, a failing create, no URL in the output', () async {
    final id = await newItem('Export CSV', branch: 'agent/work');
    final none = await backlog(['pr', id]);
    expect(none.code, 1);
    expect(none.err, contains('no dispatcher.pr'));

    final failing = await script('fake-tea.sh', 'Error: 401 Unauthorized', exitCode: 1);
    await configure('  pr:\n    create: [sh, $failing]\n');
    final run = await backlog(['pr', id]);
    expect(run.code, 1);
    expect(run.err, allOf(contains('opening the pull request failed'), contains('401 Unauthorized')));
    expect((await item(id)).pr, isNull);
    expect(await git(remote, ['rev-parse', 'agent/work']), isNotEmpty, reason: 'the branch is pushed anyway');

    final config = File(p.join(backlogDir, 'backlog.yaml'));
    final silent = await script('fake-silent.sh', 'done');
    await config.writeAsString((await config.readAsString()).replaceAll(failing, silent));
    final noUrl = await backlog(['pr', id]);
    expect(noUrl.code, 1);
    expect(noUrl.err, contains('url_pattern'));
  });

  test('a push that fails (unknown remote) opens nothing', () async {
    final create = await script('fake-tea.sh', 'https://git.example/o/r/pulls/7');
    await configure('  pr:\n    remote: nowhere\n    create: [sh, $create]\n');
    final id = await newItem('Export CSV', branch: 'agent/work');
    final run = await backlog(['pr', id]);
    expect(run.code, 1);
    expect(run.err, contains('git push nowhere agent/work failed'));
    expect(File(calls).existsSync(), isFalse);
  });
}
