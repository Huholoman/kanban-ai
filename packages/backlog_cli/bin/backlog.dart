import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backlog_cli/backlog_cli.dart';
import 'package:dart_tui/dart_tui.dart' show Program, withAltScreen;

Future<void> main(List<String> arguments) async {
  // A reader that stops early (`kanban-ai view … | head`) closes the pipe:
  // the rest of the output goes nowhere, like with other Unix tools.
  unawaited(stdout.done.catchError(_ignoreBrokenPipe));
  unawaited(stderr.done.catchError(_ignoreBrokenPipe));
  exitCode = await runBacklogCli(
    arguments,
    CliContext(
      out: stdout,
      err: stderr,
      cwd: Directory.current.path,
      environment: Platform.environment,
      readInput: () => stdin.transform(utf8.decoder).join(),
      runTui: stdin.hasTerminal && stdout.hasTerminal ? (app) => Program(options: [withAltScreen()]).run(app) : null,
      runServer: _runServer,
    ),
  );
}

/// Runs the server that belongs to this program with its output on the
/// terminal until it ends; its exit code is ours. Ctrl+C reaches it from the
/// terminal (this process waits for it to stop), `kill` is passed on.
Future<int> _runServer(List<String> arguments) async {
  final program = serverProgramFor(Platform.executable);
  final Process server;
  try {
    server = await Process.start(program, arguments, mode: ProcessStartMode.inheritStdio);
  } on ProcessException catch (error) {
    stderr.writeln('error: cannot run $program: ${error.message}');
    return 1;
  }
  final signals = [
    ProcessSignal.sigint.watch().listen((_) {}),
    ProcessSignal.sigterm.watch().listen((signal) => server.kill(signal)),
  ];
  final code = await server.exitCode;
  for (final subscription in signals) {
    await subscription.cancel();
  }
  // Ended by a signal (a negative code): 128 + its number, like a shell.
  return code < 0 ? 128 - code : code;
}

const _brokenPipe = 32; // EPIPE

void _ignoreBrokenPipe(Object error, StackTrace stack) {
  final code = switch (error) {
    FileSystemException(:final osError) => osError?.errorCode,
    SocketException(:final osError) => osError?.errorCode,
    _ => null,
  };
  if (code != _brokenPipe) Error.throwWithStackTrace(error, stack);
}
