/// The `backlog` command-line interface.
library;

import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';

import 'src/cli_context.dart';
import 'src/commands/action_commands.dart';
import 'src/commands/discussion_commands.dart';
import 'src/commands/item_commands.dart';
import 'src/commands/project_commands.dart';
import 'src/commands/view_commands.dart';
import 'src/commands/work_commands.dart';
import 'src/render/json_output.dart';

export 'src/cli_context.dart';

/// Exit codes, so that scripts and agents can react without parsing text.
abstract final class ExitCode {
  static const ok = 0;
  static const failure = 1;
  static const nothingToDo = 2;
  static const conflict = 3;
  static const notFound = 4;
  static const usage = 64;
}

Future<int> runBacklogCli(List<String> arguments, CliContext context) async {
  final runner = CommandRunner<int>('backlog', 'File-based backlog for humans and coding agents.')
    ..argParser.addOption(
      'dir',
      abbr: 'C',
      help: 'Backlog folder (default: \$BACKLOG_DIR, or found from the current folder upwards).',
    )
    ..argParser.addFlag('json', negatable: false, help: 'Machine-readable output.');
  for (final command in [
    InitCommand(context),
    NewCommand(context),
    ListCommand(context),
    ShowCommand(context),
    PathCommand(context),
    SetCommand(context),
    ReadyCommand(context),
    BlockedCommand(context),
    NextCommand(context),
    ClaimCommand(context),
    HeartbeatCommand(context),
    ReleaseCommand(context),
    DoneCommand(context),
    CommentCommand(context),
    AskCommand(context),
    ActionCommand(context),
    ClaimsCommand(context),
    ViewCommand(context),
    LintCommand(context),
    PrCommand(context),
    InstructionsCommand(context),
    ProjectsCommand(context),
  ]) {
    runner.addCommand(command);
  }

  final json = arguments.contains('--json');
  try {
    return await runner.run(arguments) ?? ExitCode.ok;
  } on UsageException catch (e) {
    context.err.writeln(e);
    return ExitCode.usage;
  } on BacklogException catch (e) {
    if (json) {
      context.out.writeln(jsonEncode(JsonOutput.error(e)));
    }
    context.err.writeln('error: ${e.message}');
    return switch (e) {
      ClaimConflictException() => ExitCode.conflict,
      NotFoundException() || AmbiguousReferenceException() => ExitCode.notFound,
      _ => ExitCode.failure,
    };
  }
}
