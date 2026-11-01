import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:backlog_cli/backlog_cli.dart';
import 'package:dart_tui/dart_tui.dart' show Program, withAltScreen;

Future<void> main(List<String> arguments) async {
  // A reader that stops early (`backlog view … | head`) closes the pipe:
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
    ),
  );
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
