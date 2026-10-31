import 'dart:convert';
import 'dart:io';

import 'package:backlog_cli/backlog_cli.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `backlog review` in a git repository: the verdict as a review comment that
/// names the reviewed head of the item's branch.
void main() {
  late Directory workspace;
  late String backlogDir, repo;
  final clock = FixedClock(DateTime.utc(2026, 10, 31, 12));

  Future<({int code, String out, String err})> backlog(
    List<String> args, {
    String? input,
    Map<String, String> env = const {'BACKLOG_AGENT': 'reviewer'},
  }) async {
    final out = StringBuffer(), err = StringBuffer();
    final code = await runBacklogCli(
      args,
      CliContext(
        out: out,
        err: err,
        cwd: repo,
        environment: env,
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

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('backlog_review_');
    backlogDir = p.join(workspace.path, 'backlog');
    repo = p.join(workspace.path, 'repo');
    await git(workspace.path, ['init', '-q', '-b', 'main', repo]);
    await git(repo, ['commit', '-q', '--allow-empty', '-m', 'init']);
    await git(repo, ['switch', '-q', '-c', 'agent/work']);
    await git(repo, ['commit', '-q', '--allow-empty', '-m', 'Do the work']);
    await git(repo, ['switch', '-q', 'main']);
    final out = StringBuffer();
    expect(
      await runBacklogCli([
        'init',
        backlogDir,
        '--prefix',
        'RV',
        '--no-register',
      ], CliContext(out: out, err: out, cwd: workspace.path)),
      0,
      reason: '$out',
    );
  });

  tearDown(() => workspace.delete(recursive: true));

  test('records the verdict with the head of the item\'s branch; it is no reply and no answer', () async {
    final id = await newItem('Export CSV', branch: 'agent/work');
    final head = await git(repo, ['rev-parse', 'agent/work']);
    await backlog(['ask', id, 'Which format?'], env: const {'BACKLOG_AGENT': 'w2'});

    final changes = await backlog([
      '--json',
      'review',
      id,
      '--changes',
      '-',
    ], input: 'Two problems.\n\n1. lib/a.dart:3 – off by one.\n2. No test.\n');
    expect(changes.code, 0, reason: changes.err);
    final json = jsonDecode(changes.out) as Map;
    expect(json['needs_human'], isTrue, reason: 'a review answers no question');
    expect((json['discussion'] as List).last, {
      'author': 'reviewer',
      'at': '2026-10-31T12:00:00.000Z',
      'text': 'Two problems.\n\n1. lib/a.dart:3 – off by one.\n2. No test.',
      'question': false,
      'note': false,
      'review': 'changes',
      'commit': head.substring(0, 12),
    });
    expect(
      File(json['path'] as String).readAsStringSync(),
      contains('### reviewer · 2026-10-31 12:00:00 UTC · review changes @${head.substring(0, 12)}\n\nTwo problems.'),
    );

    Future<Map<Object?, Object?>> listed() async =>
        ((jsonDecode((await backlog(['--json', 'list', '-w', 'review=changes,stale'])).out) as List).single as Map);
    expect(json['review'], 'changes');
    expect(json['review_findings'], 2);
    expect((await backlog(['show', id])).out, contains('REVIEW: CHANGES (2 FINDINGS) (reviewer)'));

    // The branch heads come from the dispatcher's worktrees (or repo).
    final config = File(p.join(backlogDir, 'backlog.yaml'));
    config.writeAsStringSync('${config.readAsStringSync()}\ndispatcher:\n  worktrees: [{name: repo, path: ../repo}]\n');
    expect((await listed())['review'], 'changes');
    await git(repo, ['switch', '-q', 'agent/work']);
    await git(repo, ['commit', '-q', '--allow-empty', '-m', 'Fix the findings']);
    expect((await listed())['review'], 'stale', reason: 'new commits after the review');
    expect((await backlog(['list'])).out, contains('review outdated (newer commits)'));

    final ok = await backlog(['review', id, '--ok', '--as', 'tobik']);
    expect(ok.code, 0, reason: ok.err);
    final fixed = await git(repo, ['rev-parse', 'agent/work']);
    expect(ok.out, contains('Reviewed $id of ${fixed.substring(0, 12)}: ok.'));
    final last = Discussion.parse((await (await Backlog.open(backlogDir)).items.get(id)).body).lastReview!;
    expect((last.author, last.review, last.text), ('tobik', ReviewVerdict.ok, 'No findings.'));
    expect((await backlog(['list'])).out, contains('review ok'));
  });

  test('names the given commit, none without a known branch; refuses bad input', () async {
    final id = await newItem('Export CSV');
    final noBranch = await backlog(['--json', 'review', id, '--ok', 'Fine.']);
    expect(noBranch.code, 0, reason: noBranch.err);
    expect(((jsonDecode(noBranch.out) as Map)['discussion'] as List).last, containsPair('commit', null));

    final main = await git(repo, ['rev-parse', 'HEAD']);
    final given = await backlog(['--json', 'review', id, '--ok', '--commit', 'HEAD']);
    expect(((jsonDecode(given.out) as Map)['discussion'] as List).last, containsPair('commit', main.substring(0, 12)));

    expect((await backlog(['review', id, 'x'])).code, ExitCode.usage, reason: 'no verdict');
    expect((await backlog(['review', id, '--ok', '--changes', 'x'])).code, ExitCode.usage);
    expect((await backlog(['review', id, '--changes'])).code, ExitCode.failure, reason: 'changes need findings');
    expect((await backlog(['review', id, '--ok', '--commit', 'nope'])).code, ExitCode.failure);
  });
}
