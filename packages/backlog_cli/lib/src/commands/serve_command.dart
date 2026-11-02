import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'backlog_command.dart';

/// `kanban-ai serve [server options]`: runs the server program that belongs
/// to this CLI ([serverProgramFor]) with the given options, and `-C` when
/// it was given before `serve`.
final class ServeCommand extends BacklogCommand {
  ServeCommand(super.context);

  /// Everything after `serve` is the server's (`kanban-ai serve --help`
  /// lists it).
  @override
  final ArgParser argParser = ArgParser.allowAnything();

  @override
  String get name => 'serve';

  @override
  String get description =>
      'Run the server (kanban-ai-server: the web board, its API and the dispatcher) with the given options; '
      '`kanban-ai serve --help` lists them.';

  @override
  String get invocation => 'kanban-ai serve [server options]';

  @override
  Future<int> run() async {
    final runServer =
        context.runServer ?? (throw UsageException('`kanban-ai serve` cannot start programs here.', usage));
    final dir = globalResults!.option('dir');
    return runServer([
      if (dir != null) ...['--dir', p.normalize(p.join(context.cwd, dir))],
      ...args.arguments,
    ]);
  }
}

/// The server program that belongs to the CLI run as [executable]: next to
/// it when [executable] is a path, else looked up on the `PATH`. Its name
/// follows the CLI's: `kanban-ai` → `kanban-ai-server`, `kanban-ai-dev` →
/// `kanban-ai-server-dev`, the older `backlog` → `backlog-server`; any
/// other program (`dart` running the sources) → `kanban-ai-server`.
String serverProgramFor(String executable) {
  final name = p.basename(executable);
  final match = RegExp(r'^(kanban-ai|backlog)(-dev)?$').firstMatch(name);
  if (match == null) return 'kanban-ai-server';
  final server = '${match.group(1)}-server${match.group(2) ?? ''}';
  return executable.contains(p.separator) ? p.join(p.dirname(executable), server) : server;
}
