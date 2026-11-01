import 'dart:io';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_server/backlog_server.dart';
import 'package:test/test.dart';

Future<String> _git(String dir, List<String> arguments) async {
  final result = await Process.run('git', arguments, workingDirectory: dir);
  if (result.exitCode != 0) throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
  return '${result.stdout}';
}

void main() {
  late String root;
  late BacklogHost host;
  final logs = <String>[];

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('autocommit_test_');
    addTearDown(() => dir.delete(recursive: true));
    root = dir.path;
    await Backlog.init(root);
    await _git(root, ['init', '-q', '-b', 'main']);
    await _git(root, ['config', 'user.email', 'test@example.com']);
    await _git(root, ['config', 'user.name', 'Test']);
    await _git(root, ['add', '.']);
    await _git(root, ['commit', '-q', '-m', 'init']);
    host = BacklogHost(FileBacklogStorage(root));
    logs.clear();
  });

  Future<int> commits() async => int.parse((await _git(root, ['rev-list', '--count', 'HEAD'])).trim());

  Future<void> commitsReach(int count) async {
    for (var i = 0; i < 100 && await commits() < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(await commits(), count, reason: '$logs');
  }

  test('commits once the backlog is quiet, and right after a run', () async {
    final auto = BacklogAutoCommit(
      host,
      quiet: const Duration(milliseconds: 50),
      afterRun: const Duration(milliseconds: 10),
      log: logs.add,
    );
    addTearDown(auto.close);
    final item = await (await host.backlog).items.create(const NewItem(title: 'Hello', status: 'todo'));
    auto.changed(const BacklogChangeEvent(['.locks/x.lock']));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(await commits(), 1, reason: 'claim locks alone are no change');

    auto.changed(BacklogChangeEvent(['items/${item.id}-hello.md']));
    await commitsReach(2);
    expect(logs.single, 'Backlog: committed 1 file(s): Backlog: ${item.id} new');

    await (await host.backlog).items.update(item.id.value, [FieldChange.parse('status=review')]);
    auto.runEnded();
    await commitsReach(3);
    expect(await _git(root, ['log', '-1', '--format=%s']), 'Backlog: ${item.id} status review\n');
  });

  test('git.commit: off leaves the backlog to people', () async {
    final config = File('$root/backlog.yaml');
    await config.writeAsString('${await config.readAsString()}\ngit:\n  commit: off\n');
    final auto = BacklogAutoCommit(host, log: logs.add);
    await (await host.backlog).items.create(const NewItem(title: 'Hello'));
    await auto.flush();
    await auto.close();
    expect(await commits(), 1);
    expect(logs, isEmpty);
  });
}
