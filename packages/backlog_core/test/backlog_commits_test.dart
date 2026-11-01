import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Future<String> _git(String dir, List<String> arguments) async {
  final result = await Process.run('git', arguments, workingDirectory: dir);
  if (result.exitCode != 0) throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
  return '${result.stdout}';
}

void main() {
  late Backlog backlog;
  late String root;

  setUp(() async {
    final (opened, _) = await tempBacklog();
    backlog = opened;
    root = opened.root;
    await _git(root, ['init', '-q', '-b', 'main']);
    await _git(root, ['config', 'user.email', 'test@example.com']);
    await _git(root, ['config', 'user.name', 'Test']);
    await _git(root, ['add', '.']);
    await _git(root, ['commit', '-q', '-m', 'init']);
  });

  test('commits what changed, naming the items and what happened to them', () async {
    final commits = BacklogCommits(root);
    expect(await commits.ownsRepository(), isTrue);
    expect(await commits.commit(), isNull, reason: 'nothing changed');

    final first = await backlog.items.create(const NewItem(title: 'First item', status: 'todo'));
    final second = await backlog.items.create(const NewItem(title: 'Second item', status: 'todo'));
    await _git(root, ['add', '.']);
    await _git(root, ['commit', '-q', '-m', 'items']);

    await backlog.items.update(first.id.value, [FieldChange.parse('status=review')]);
    await backlog.items.comment(first.id.value, author: 'wt-2', text: 'Done.');
    await backlog.items.comment(first.id.value, author: 'kanban-ai', text: 'Ran.', note: true);
    await backlog.items.update(second.id.value, [FieldChange.parse('priority=p0')]);
    final third = await backlog.items.create(const NewItem(title: 'Third'));
    await backlog.claims.claim(second.id.value, 'wt-3', force: true);

    final commit = (await commits.commit(ids: [first.id.value, second.id.value, third.id.value]))!;
    expect(
      commit.subject,
      'Backlog: ${first.id} status review, comment by wt-2, note by kanban-ai; '
      '${second.id} status in-progress, priority p0; ${third.id} new',
    );
    expect(commit.paths, isNot(contains(startsWith('.locks'))));
    expect(commit.pushError, isNull);
    expect(await _git(root, ['status', '--porcelain', '--', ':(exclude).locks']), isEmpty);
    expect(await _git(root, ['log', '-1', '--format=%s']), '${commit.subject}\n');
  });

  test('a backlog inside another repository is not committed', () async {
    final nested = Directory(p.join(root, 'sub'));
    await nested.create();
    await Backlog.init(nested.path);
    expect(await BacklogCommits(nested.path).ownsRepository(), isFalse);
    expect(await BacklogCommits(nested.path).commit(), isNull);
    expect(await _git(root, ['status', '--porcelain']), contains('sub/'));
  });
}
