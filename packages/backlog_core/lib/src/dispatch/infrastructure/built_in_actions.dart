import 'dart:convert';
import 'dart:io';

import '../../backlog.dart';
import '../../planning/domain/planned_item.dart';
import '../../workflow/domain/action_definition.dart';
import '../../workflow/domain/dispatcher_config.dart';
import '../domain/action_run.dart';
import 'merge_action.dart';

/// What a built-in action gets to work with.
final class BuiltInActionContext {
  BuiltInActionContext({
    required this.item,
    required this.action,
    required this.config,
    required this.backlog,
    required this.backlogRoot,
    required this.path,
    required this.values,
    required this.environment,
    required void Function(String line) log,
    this.worktree,
    this.trigger = ActionTrigger.request,
    this.from,
    this.stateDir,
    this.project,
  }) : _log = log;

  /// Why it runs: a person asked, or the item entered the `on_enter` status.
  final ActionTrigger trigger;

  /// For a hook: the status the item was in before it entered the
  /// `on_enter` status; null otherwise (or when not known).
  final String? from;

  /// The dispatcher's state folder and the project id (records of created
  /// worktrees and agent sessions); null outside a launcher.
  final String? stateDir;
  final String? project;

  /// The item as it was when the action started.
  final PlannedItem item;
  final ActionDefinition action;
  final DispatcherConfig config;

  /// The backlog, to change the item (status, comments) through its
  /// services.
  final Backlog backlog;
  final String backlogRoot;

  /// The dispatcher worktree that has the item's branch checked out; null
  /// when there is none (then [path] is the primary clone, or the backlog
  /// folder without `dispatcher.repo`).
  final String? worktree;

  /// Absolute working directory.
  final String path;

  /// The command placeholders ([ActionDefinition.commandPlaceholders])
  /// filled in for the item.
  final Map<String, String> values;

  /// The environment for programs it runs: the server's plus
  /// `BACKLOG_DIR`, `KANBAN_AI_ITEM`, `KANBAN_AI_ACTION` (and
  /// `BACKLOG_AGENT` in a worktree).
  final Map<String, String> environment;
  final void Function(String line) _log;

  /// Appends [line] to the action's log (the board shows it live).
  void log(String line) => _log(line);

  /// Runs [command] (no shell) in [workingDirectory] (default [path]) with
  /// [environment]; its output goes to the log. Returns the exit code.
  Future<int> run(List<String> command, {String? workingDirectory}) async =>
      (await capture(command, workingDirectory: workingDirectory)).exitCode;

  /// Like [run], and also returns the output (standard output and error).
  Future<CommandOutput> capture(List<String> command, {String? workingDirectory}) async {
    log('\$ ${CommandTemplate.join(command)}');
    final Process process;
    try {
      process = await Process.start(
        command.first,
        command.skip(1).toList(),
        workingDirectory: workingDirectory ?? path,
        environment: environment,
        includeParentEnvironment: false,
      );
    } on ProcessException catch (error) {
      log('cannot run ${command.first}: ${error.message}');
      return CommandOutput(127, 'cannot run ${command.first}: ${error.message}');
    }
    await process.stdin.close();
    final output = StringBuffer();
    void line(String text) {
      log(text);
      output.writeln(text);
    }

    await Future.wait([
      for (final stream in [process.stdout, process.stderr])
        stream.transform(utf8.decoder).transform(const LineSplitter()).forEach(line),
    ]);
    return CommandOutput(await process.exitCode, '$output');
  }
}

/// The exit code and output (standard output and error) of a program.
final class CommandOutput {
  const CommandOutput(this.exitCode, this.output);

  final int exitCode;
  final String output;

  bool get ok => exitCode == 0;
}

/// How a built-in action ended: [ok] and one line for the item's
/// discussion and the log.
final class BuiltInActionResult {
  const BuiltInActionResult({required this.ok, required this.summary});

  final bool ok;
  final String summary;
}

/// An action built into kanban-ai (`run: <name>` in `dispatcher.actions`).
/// It runs inside the server (not detached): a restart of the server while
/// it runs ends it as interrupted. Long work belongs in programs it starts
/// with [BuiltInActionContext.run].
abstract interface class BuiltInAction {
  /// The name in `run:`; must be listed in [ActionDefinition.builtIns].
  String get name;

  Future<BuiltInActionResult> run(BuiltInActionContext context);
}

/// The built-in actions, by name. [ActionDefinition.builtIns] lists the
/// names `backlog.yaml` accepts; every one of them has an implementation
/// here.
abstract final class BuiltInActions {
  static final Map<String, BuiltInAction> standard = {
    for (final action in <BuiltInAction>[const NoopAction(), const MergeAction()]) action.name: action,
  };
}

/// Does nothing and succeeds; for trying actions and hooks out.
final class NoopAction implements BuiltInAction {
  const NoopAction();

  @override
  String get name => 'noop';

  @override
  Future<BuiltInActionResult> run(BuiltInActionContext context) async {
    context.log('noop: nothing to do for ${context.item.id} (${context.item.item.status}).');
    return const BuiltInActionResult(ok: true, summary: 'did nothing (noop)');
  }
}
