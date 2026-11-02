import 'dart:convert';
import 'dart:io';

import 'package:backlog_cli/backlog_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `backlog suggest-touches`: the answer of the `touches.suggest` command,
/// checked against the files of the code repository, saved on request.
void main() {
  late Directory workspace;
  late String backlogDir, repo;

  Future<({int code, String out, String err})> backlog(List<String> args) async {
    final out = StringBuffer(), err = StringBuffer();
    final code = await runBacklogCli(
      args,
      CliContext(out: out, err: err, cwd: repo, environment: {'BACKLOG_DIR': backlogDir}),
    );
    return (code: code, out: '$out', err: '$err');
  }

  Future<void> git(List<String> args) async {
    final result = await Process.run('git', [
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      ...args,
    ], workingDirectory: repo);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('backlog_touches_');
    addTearDown(() => workspace.delete(recursive: true));
    backlogDir = p.join(workspace.path, 'backlog');
    repo = p.join(workspace.path, 'repo');
    await Directory(repo).create();
    await git(['init', '-q', '-b', 'main']);
    for (final path in ['lib/payments/pay.dart', 'README.md']) {
      await File(p.join(repo, path)).create(recursive: true);
    }
    await git(['add', '.']);
    await git(['commit', '-q', '-m', 'init']);
    final out = StringBuffer();
    expect(
      await runBacklogCli([
        'init',
        backlogDir,
        '--prefix',
        'TS',
        '--no-register',
      ], CliContext(out: out, err: out, cwd: workspace.path)),
      0,
      reason: '$out',
    );
  });

  Future<void> configure(String answer) async {
    final config = File(p.join(backlogDir, 'backlog.yaml'));
    await config.writeAsString(
      '${await config.readAsString()}\ntouches:\n  repo: ../repo\n  suggest: [sh, -c, "cat >/dev/null; printf -- \'$answer\'"]\n',
    );
  }

  test('without touches.suggest there is nothing to ask', () async {
    expect((await backlog(['new', 'Refunds'])).code, 0);
    final run = await backlog(['suggest-touches', 'TS']);
    expect(run.code, isNot(0));
    expect(run.err, contains('touches.suggest'));
  });

  test('prints the suggestion and the entries left out; saves nothing', () async {
    await configure(r'- lib/payments/\n- src/x.c\n');
    final id = (jsonDecode((await backlog(['--json', 'new', 'Refunds', '--touches', 'README.md'])).out) as Map)['id'];
    final run = await backlog(['suggest-touches', '$id']);
    expect(run.code, 0, reason: run.err);
    expect(
      run.out,
      'Suggested touches for $id (not saved; --add or --replace saves them):\n'
      '  lib/payments/\n'
      'left out: src/x.c (matches nothing in the repository)\n',
    );
    final json = jsonDecode((await backlog(['--json', 'suggest-touches', '$id'])).out);
    expect(json, {
      'id': id,
      'suggested': ['lib/payments/'],
      'rejected': [
        {'entry': 'src/x.c', 'reason': 'matches nothing in the repository'},
      ],
      'saved': false,
      'touches': ['README.md'],
    });
  });

  test('--add and --replace save the suggestion', () async {
    await configure(r'lib/payments/\nlib/{a,b}.dart\n');
    final id = (jsonDecode((await backlog(['--json', 'new', 'Refunds', '--touches', 'README.md'])).out) as Map)['id'];
    final added = await backlog(['suggest-touches', '$id', '--add']);
    expect(added.code, 0, reason: added.err);
    expect(added.out, contains('touches: README.md, lib/payments/, lib/{a,b}.dart'));
    final replaced = jsonDecode((await backlog(['--json', 'suggest-touches', '$id', '--replace'])).out);
    expect(replaced['saved'], isTrue);
    expect(replaced['touches'], ['lib/payments/', 'lib/{a,b}.dart']);
    expect((await backlog(['suggest-touches', '$id', '--add', '--replace'])).code, isNot(0));
  });
}
