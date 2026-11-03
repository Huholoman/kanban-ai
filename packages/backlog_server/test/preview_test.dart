@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_server/backlog_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('backlog_preview_'));
  tearDown(() => dir.delete(recursive: true));

  group('/api/preview', () {
    late BacklogServer server;
    late HttpProjectsApi api;
    late _FakeServer control;
    late FilePreviewStore store;

    final state = PreviewState(
      project: 'alpha',
      item: 'A-0001',
      title: 'Feature',
      branch: 'agent/A-0001',
      commit: 'abcdef1234567890',
      base: 'main',
      since: DateTime.utc(2026, 11, 1, 12),
      server: 'board-preview',
      mainServer: 'board-main',
    );

    setUp(() async {
      final root = p.join(dir.path, 'backlog');
      await Backlog.init(root, idPrefix: 'A');
      control = _FakeServer();
      store = FilePreviewStore(p.join(dir.path, 'state'));
      server = await BacklogServer.start(
        root: root,
        addresses: [InternetAddress.loopbackIPv4],
        port: 0,
        preview: LocalPreview(store: store, server: control),
      );
      api = HttpProjectsApi(server.uri);
    });

    tearDown(() async {
      api.close();
      await server.close();
    });

    test('says what preview runs and goes back to main', () async {
      expect(await api.preview(), isNull);
      await store.write(state);
      expect(await api.preview(), isNull, reason: 'this server was not started for it');

      control.preview = state.commit;
      final preview = (await api.preview())!;
      expect(
        (preview.item, preview.branch, preview.shortCommit, preview.since),
        ('A-0001', 'agent/A-0001', 'abcdef1', DateTime.utc(2026, 11, 1, 12)),
      );

      expect((await api.backToMain()).item, 'A-0001');
      expect(await store.read(), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(control.restarts, ['board-main']);
      await expectLater(
        api.backToMain(),
        throwsA(isA<BacklogApiException>().having((e) => e.statusCode, 'statusCode', 400)),
      );
    });

    test('a main server that does not run keeps the preview', () async {
      await store.write(state);
      control
        ..preview = state.commit
        ..problem = 'cannot run board-main';
      await expectLater(
        api.backToMain(),
        throwsA(isA<BacklogApiException>().having((e) => e.message, 'message', 'cannot run board-main')),
      );
      expect(await store.read(), isNotNull);
    });
  });

  group('/api/commands', () {
    late BacklogServer server;
    late HttpProjectsApi api;
    late _FakeServer control;

    setUp(() async {
      final root = p.join(dir.path, 'backlog');
      await Backlog.init(root, idPrefix: 'A');
      control = _FakeServer();
      server = await BacklogServer.start(
        root: root,
        addresses: [InternetAddress.loopbackIPv4],
        port: 0,
        commands: ServerCommands(
          const [
            ServerCommand(name: 'Update', command: ['sh', '-c', 'echo updated'], restart: ServerCommand.sameProgram),
            ServerCommand(name: 'Slow check', command: ['sleep', '0.3']),
          ],
          server: control,
          restartDelay: Duration.zero,
        ),
      );
      api = HttpProjectsApi(server.uri);
    });

    tearDown(() async {
      api.close();
      await server.close();
    });

    Future<CommandRunDto> ended() async {
      for (var i = 0; i < 100; i++) {
        final run = (await api.commands()).run!;
        if (!run.running) return run;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('the command did not end');
    }

    test('lists the commands, runs one at a time and reports the result', () async {
      final listed = await api.commands();
      expect(
        [for (final command in listed.commands) (command.name, command.restarts)],
        [('Update', true), ('Slow check', false)],
      );
      expect(listed.run, isNull);

      expect((await api.runCommand('Slow check')).running, isTrue);
      await expectLater(
        api.runCommand('Update'),
        throwsA(isA<BacklogApiException>().having((e) => e.statusCode, 'statusCode', 409)),
      );
      expect((await ended()).succeeded, isTrue);

      await api.runCommand('Update');
      final run = await ended();
      expect((run.name, run.exitCode, run.output, run.restart), ('Update', 0, 'updated\n', 'board-preview'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(control.restarts, ['board-preview']);
      await expectLater(
        api.runCommand('Nope'),
        throwsA(isA<BacklogApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });

  group('ProcessServerControl', () {
    ProcessServerControl control({int? processId, List<String> arguments = const [], void Function()? stopped}) =>
        ProcessServerControl(
          program: 'kanban-ai-server',
          arguments: arguments,
          environment: {
            'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
            'KANBAN_AI_WEB': '/nix/store/old-web',
            'BACKLOG_WEB': '/nix/store/old-web',
            'KANBAN_AI_PREVIEW': 'old',
            'KEEP': 'yes',
          },
          log: p.join(dir.path, 'state', 'server.log'),
          stop: () async => stopped?.call(),
          workingDirectory: dir.path,
          processId: processId,
        );

    test('the new server gets the environment without the old web app, marked with its program', () {
      final server = control();
      expect(server.preview, 'old');
      expect(server.environmentFor('kanban-ai-server-dev', preview: 'abc'), {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'KEEP': 'yes',
        'KANBAN_AI_SERVER_PROGRAM': 'kanban-ai-server-dev',
        'KANBAN_AI_PREVIEW': 'abc',
      });
      expect(server.environmentFor('kanban-ai-server'), isNot(contains('KANBAN_AI_PREVIEW')));
      expect(ProcessServerControl.programOf({'KANBAN_AI_SERVER_PROGRAM': 'x'}, 'y'), 'x');
      expect(ProcessServerControl.programOf({}, 'y'), 'y');
    });

    test('a program that is missing or fails its --help is a problem', () async {
      final server = control();
      expect(await server.problemWith('true'), isNull);
      expect(await server.problemWith('false'), '`false --help` exited with code 1');
      expect(await server.problemWith('/no/such/server'), startsWith('cannot run /no/such/server'));
    });

    test('restart starts the program with the same arguments once the old process has ended', () async {
      final old = await Process.start('sleep', ['0.5']);
      final out = p.join(dir.path, 'out.txt');
      var stopped = false;
      final server = control(
        processId: old.pid,
        arguments: ['-c', 'printf "%s %s %s" "\$KANBAN_AI_SERVER_PROGRAM" "\$KANBAN_AI_PREVIEW" "\$KEEP" > $out'],
        stopped: () => stopped = true,
      );
      await server.restart('sh', preview: 'abc');
      expect(stopped, isTrue);
      expect(File(out).existsSync(), isFalse, reason: 'the old process still runs');
      await old.exitCode;
      for (var i = 0; i < 50 && !File(out).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(File(out).readAsStringSync(), 'sh abc yes');
      expect(File(p.join(dir.path, 'state', 'server.log')).readAsStringSync(), contains('restarting the server as sh'));
    });
  });
}

final class _FakeServer implements ServerControl {
  @override
  String program = 'board-preview';
  @override
  String? preview;
  String? problem;
  final restarts = <String>[];

  @override
  Future<String?> problemWith(String program) async => problem;

  @override
  Future<void> restart(String program, {String? preview}) async => restarts.add(program);
}
