import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../settings/domain/server_config.dart';
import '../../shared/clock.dart';
import '../../shared/errors.dart';
import '../domain/command_run.dart';
import '../domain/preview.dart';

/// The global commands of the server (`commands` in `server.yaml`) for the
/// board's command menu: one runs at a time ([start]); [last] is the
/// running one or the one that ran last, with its output so far. When a
/// command with `restart` succeeds, the server restarts as that program
/// (after [restartDelay], time for the board to see the result).
final class ServerCommands {
  ServerCommands(
    this.commands, {
    this.server,
    this.clock = const SystemClock(),
    this.restartDelay = const Duration(seconds: 2),
    this.maxOutput = 64 * 1024,
  });

  final List<ServerCommand> commands;

  /// Null when this server cannot restart itself.
  final ServerControl? server;
  final Clock clock;
  final Duration restartDelay;

  /// How much of the output [last] keeps (its end).
  final int maxOutput;

  CommandRun? _last;
  final _output = StringBuffer();

  /// The running command or the one that ran last; null before the first.
  CommandRun? get last => switch (_last) {
    null => null,
    final run => CommandRun(
      name: run.name,
      started: run.started,
      finished: run.finished,
      exitCode: run.exitCode,
      output: _output.toString(),
      error: run.error,
      restart: run.restart,
    ),
  };

  /// Starts command [name] and returns its run as it starts. Refused while
  /// another one runs.
  Future<CommandRun> start(String name) async {
    final command = commands.where((command) => command.name == name).firstOrNull;
    if (command == null) throw NotFoundException('There is no command "$name".');
    if (_last case final running? when running.running) {
      throw UnavailableException('"${running.name}" is running; try again when it ends.');
    }
    if (_starting) throw const UnavailableException('Another command is starting; try again in a moment.');
    _starting = true;
    try {
      return await _start(command);
    } finally {
      _starting = false;
    }
  }

  bool _starting = false;

  Future<CommandRun> _start(ServerCommand command) async {
    final restart = command.restart == null
        ? null
        : command.restart == ServerCommand.sameProgram
        ? server?.program
        : command.restart;
    if (command.restart != null) {
      if (server == null) throw const UnavailableException('This server cannot restart itself.');
      if (await server!.problemWith(restart!) case final problem?) throw UnavailableException(problem);
    }
    _output.clear();
    _last = CommandRun(name: command.name, started: clock.now());
    unawaited(_run(command, restart));
    return last!;
  }

  Future<void> _run(ServerCommand command, String? restart) async {
    final started = _last!.started;
    void finish({int? exitCode, String? error, String? restarting}) => _last = CommandRun(
      name: command.name,
      started: started,
      finished: clock.now(),
      exitCode: exitCode,
      error: error,
      restart: restarting,
    );

    final Process process;
    try {
      process = await Process.start(
        command.command.first,
        command.command.skip(1).toList(),
        workingDirectory: command.dir,
      );
    } on ProcessException catch (e) {
      finish(error: 'cannot run ${command.command.first}: ${e.message}');
      return;
    }
    await process.stdin.close();
    final done = [
      for (final stream in [process.stdout, process.stderr])
        stream.transform(const Utf8Decoder(allowMalformed: true)).forEach(_append),
    ];
    final exitCode = await process.exitCode;
    await Future.wait(done);
    if (exitCode != 0 || restart == null) return finish(exitCode: exitCode);
    finish(exitCode: exitCode, restarting: restart);
    Future<void>.delayed(restartDelay, () async {
      try {
        await server!.restart(restart);
      } catch (e) {
        finish(exitCode: exitCode, error: 'the server could not restart as $restart: $e');
      }
    }).ignore();
  }

  void _append(String text) {
    _output.write(text);
    if (_output.length <= maxOutput) return;
    final all = _output.toString();
    _output
      ..clear()
      ..write(all.substring(all.length - maxOutput));
  }
}
