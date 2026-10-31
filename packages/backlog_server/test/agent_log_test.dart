import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_server/backlog_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A launcher whose log source the test sets.
final class _LogLauncher extends AgentLauncher {
  AgentLogSource? source;

  @override
  Future<void> launch(DispatchAssignment assignment) async {}

  @override
  Future<AgentLogSource?> agentLogSource(ItemId item) async => source;
}

String _event(Map<String, Object?> json) => '${jsonEncode(json)}\n';

void main() {
  late Directory dir;
  late File log;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('agent_log_');
    addTearDown(() => dir.delete(recursive: true));
    log = File(p.join(dir.path, 'X-1.log'));
  });

  group('AgentLogFollower', () {
    test('starts with the tail, then reports appended complete lines and the end of the run', () async {
      final launcher = _LogLauncher();
      final follower = AgentLogFollower(() => launcher.agentLogSource(ItemId('X-1')), item: 'X-1', lines: 2);

      final none = (await follower.poll())!;
      expect([none.path, none.reset, none.lines], [null, true, isEmpty]);
      expect(await follower.poll(), isNull, reason: 'still no agent');

      log.writeAsStringSync('one\ntwo\nthree\n');
      launcher.source = AgentLogSource(path: log.path, running: true);
      final first = (await follower.poll())!;
      expect(
        [first.path, first.running, first.reset, first.lines],
        [
          log.path,
          true,
          true,
          ['two', 'three'],
        ],
      );
      expect(await follower.poll(), isNull);

      log.writeAsStringSync('four\nfi', mode: FileMode.append);
      expect((await follower.poll())!.lines, ['four'], reason: 'the unfinished line waits');
      log.writeAsStringSync('ve\n', mode: FileMode.append);
      final next = (await follower.poll())!;
      expect(
        [next.reset, next.lines],
        [
          false,
          ['five'],
        ],
      );

      log.writeAsStringSync('# exited', mode: FileMode.append);
      launcher.source = AgentLogSource(path: log.path, running: false, last: const {'exit_code': 0, 'reason': 'ok'});
      final end = (await follower.poll())!;
      expect(
        [end.running, end.lines, end.last!.exitCode],
        [
          false,
          ['# exited'],
          0,
        ],
      );
      expect(await follower.poll(), isNull);
    });

    test('a new run resets; stream-json logs come condensed', () async {
      final launcher = _LogLauncher()..source = AgentLogSource(path: log.path, running: false);
      log.writeAsStringSync('old run\n');
      final follower = AgentLogFollower(() => launcher.agentLogSource(ItemId('X-1')), item: 'X-1');
      expect((await follower.poll())!.lines, ['old run']);

      final next = File(p.join(dir.path, 'X-1-2.log'))
        ..writeAsStringSync(
          _event({'type': 'system', 'subtype': 'init', 'session_id': 's-1', 'model': 'm', 'cwd': dir.path}) +
              _event({
                'type': 'assistant',
                'message': {
                  'content': [
                    {'type': 'text', 'text': 'Looking.'},
                    {
                      'type': 'tool_use',
                      'id': 't1',
                      'name': 'Read',
                      'input': {'file_path': p.join(dir.path, 'a.md')},
                    },
                  ],
                },
              }),
        );
      launcher.source = AgentLogSource(path: next.path, running: true, output: AgentOutput.claudeStreamJson);
      final reset = (await follower.poll())!;
      expect(reset.reset, isTrue);
      expect(reset.lines, ['● Claude Code · m · session s-1', 'Looking.', '▸ Read a.md']);
    });
  });

  test('WS dispatch/log/<item>/live streams the log to HttpBacklogApi.followAgentLog', () async {
    final backlogDir = Directory(p.join(dir.path, 'backlog'));
    await Backlog.init(backlogDir.path, idPrefix: 'L');
    final item = await (await Backlog.open(backlogDir.path)).items.create(const NewItem(title: 'Work'));
    final launcher = _LogLauncher();
    final server = await BacklogServer.start(
      root: backlogDir.path,
      addresses: [InternetAddress.loopbackIPv4],
      port: 0,
      launcher: (_, _, _) => launcher,
    );
    addTearDown(server.close);
    final api = HttpBacklogApi(server.uris.first);

    log.writeAsStringSync('hello\n');
    launcher.source = AgentLogSource(path: log.path, running: true);
    final updates = StreamIterator(api.followAgentLog(item.id.value.substring(2), lines: 10));
    addTearDown(updates.cancel);
    expect(await updates.moveNext().timeout(const Duration(seconds: 10)), isTrue);
    expect(
      [updates.current.item, updates.current.reset, updates.current.lines],
      [
        item.id.value,
        true,
        ['hello'],
      ],
    );

    log.writeAsStringSync('world\n', mode: FileMode.append);
    expect(await updates.moveNext().timeout(const Duration(seconds: 10)), isTrue);
    expect(
      [updates.current.reset, updates.current.lines],
      [
        false,
        ['world'],
      ],
    );

    await expectLater(
      () => api.followAgentLog('L-none').first.timeout(const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
      reason: 'an unknown item gets no messages (the upgrade is refused, the client retries)',
    );
  });
}
