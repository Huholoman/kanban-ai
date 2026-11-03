import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

void main() {
  Future<CommandRun> ended(ServerCommands commands) async {
    for (var i = 0; i < 200; i++) {
      final run = commands.last!;
      if (!run.running) return run;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('the command did not end');
  }

  test('runs a command in its folder and keeps its output and exit code', () async {
    final dir = await Directory.systemTemp.createTemp('server_commands_');
    addTearDown(() => dir.delete(recursive: true));
    final commands = ServerCommands([
      ServerCommand(name: 'Where', command: const ['sh', '-c', 'pwd; echo oops >&2; exit 3'], dir: dir.path),
    ]);
    expect(commands.last, isNull);
    final run = await commands.start('Where');
    expect((run.name, run.running), ('Where', true));
    final result = await ended(commands);
    expect(result.exitCode, 3);
    expect(result.succeeded, isFalse);
    expect(result.output, contains(dir.resolveSymbolicLinksSync()));
    expect(result.output, contains('oops'));
  });

  test('one at a time; unknown commands and programs fail', () async {
    final commands = ServerCommands(const [
      ServerCommand(name: 'Slow', command: ['sleep', '0.3']),
      ServerCommand(name: 'Missing', command: ['no-such-program-kanban-ai']),
    ]);
    await commands.start('Slow');
    expect(() => commands.start('Missing'), throwsA(isA<UnavailableException>()));
    expect(() => commands.start('Nope'), throwsA(isA<NotFoundException>()));
    expect((await ended(commands)).succeeded, isTrue);
    await commands.start('Missing');
    final missing = await ended(commands);
    expect(missing.succeeded, isFalse);
    expect(missing.error, contains('cannot run no-such-program-kanban-ai'));
  });

  test('keeps the end of a long output', () async {
    final commands = ServerCommands(const [
      ServerCommand(name: 'Loud', command: ['sh', '-c', 'seq 1 2000']),
    ], maxOutput: 100);
    await commands.start('Loud');
    final run = await ended(commands);
    expect(run.output.length, 100);
    expect(run.output.trimRight(), endsWith('2000'));
  });

  test('restarts the server after a success, not after a failure', () async {
    final server = _FakeServer();
    final commands = ServerCommands(
      const [
        ServerCommand(name: 'Update', command: ['true'], restart: ServerCommand.sameProgram),
        ServerCommand(name: 'Other', command: ['true'], restart: 'board-next'),
        ServerCommand(name: 'Broken', command: ['false'], restart: 'board-next'),
      ],
      server: server,
      restartDelay: Duration.zero,
    );

    await commands.start('Update');
    expect((await ended(commands)).restart, 'board-main');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.restarts, ['board-main']);

    await commands.start('Broken');
    expect((await ended(commands)).restart, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.restarts, ['board-main']);

    server.problem = 'cannot run board-next';
    expect(
      () => commands.start('Other'),
      throwsA(isA<UnavailableException>().having((e) => e.message, 'message', 'cannot run board-next')),
    );
    expect(
      () => ServerCommands(const [
        ServerCommand(name: 'Update', command: ['true'], restart: ServerCommand.sameProgram),
      ]).start('Update'),
      throwsA(isA<UnavailableException>()),
    );
  });
}

final class _FakeServer implements ServerControl {
  @override
  String program = 'board-main';
  @override
  String? preview;
  String? problem;
  final restarts = <String>[];

  @override
  Future<String?> problemWith(String program) async => problem;

  @override
  Future<void> restart(String program, {String? preview}) async => restarts.add(program);
}
