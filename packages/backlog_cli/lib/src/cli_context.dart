import 'package:backlog_core/backlog_core.dart';

import 'package:dart_tui/dart_tui.dart' show Model;

/// Everything the CLI takes from its process, injectable for tests.
final class CliContext {
  const CliContext({
    required this.out,
    required this.err,
    required this.cwd,
    this.environment = const {},
    this.clock = const SystemClock(),
    this.readInput,
    this.runTui,
    this.runServer,
  });

  final StringSink out;
  final StringSink err;
  final String cwd;
  final Map<String, String> environment;
  final Clock clock;

  /// Reads standard input to the end (for text given as `-`); null when
  /// there is none.
  final Future<String> Function()? readInput;

  /// Runs a `dart_tui` model in the interactive terminal until it quits
  /// (`kanban-ai config`); null when the process does not run in one.
  final Future<void> Function(Model app)? runTui;

  /// Runs the server program with these arguments, its output on the
  /// terminal, until it ends; its exit code (`kanban-ai serve`). Null when
  /// this process cannot start programs.
  final Future<int> Function(List<String> arguments)? runServer;
}
