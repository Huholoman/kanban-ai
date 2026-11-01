import 'dart:convert';
import 'dart:io';

import 'package:backlog_cli/backlog_cli.dart';
import 'package:dart_tui/dart_tui.dart' show Program, withAltScreen;

Future<void> main(List<String> arguments) async {
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
