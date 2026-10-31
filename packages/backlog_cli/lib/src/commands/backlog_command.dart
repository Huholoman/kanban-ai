import 'dart:convert';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;

import '../cli_context.dart';
import '../render/json_output.dart';
import '../render/text_output.dart';

/// Shared plumbing: finding the backlog, the agent name and printing.
abstract class BacklogCommand extends Command<int> {
  BacklogCommand(this.context);

  final CliContext context;

  bool get json => globalResults!.flag('json');

  ArgResults get args => argResults!;

  Future<Backlog> openBacklog() async => Backlog.open(backlogRoot, clock: context.clock);

  /// The backlog folder: `--dir`, `\$BACKLOG_DIR` or found from the current folder.
  String get backlogRoot {
    final explicit = globalResults!.option('dir') ?? context.environment['BACKLOG_DIR'];
    return explicit != null
        ? p.normalize(p.join(context.cwd, explicit))
        : Backlog.locate(context.cwd) ??
              (throw const NotFoundException(
                'No backlog found here or in any parent folder (looked for backlog.yaml and backlog/backlog.yaml). '
                'Use --dir, BACKLOG_DIR or `backlog init`.',
              ));
  }

  /// The project registry in [file], else where the environment points
  /// (see [projectRegistryFile]); null without any location.
  ProjectService? projectService([String? file]) {
    final location = file ?? projectRegistryFile(context.environment);
    if (location == null) return null;
    return ProjectService(
      YamlProjectRegistryStore(p.normalize(p.join(context.cwd, location)), home: context.environment['HOME']),
    );
  }

  void addAgentOption({bool mandatory = true}) => argParser.addOption(
    'as',
    help: mandatory
        ? 'Agent name, e.g. the worktree (default: \$BACKLOG_AGENT).'
        : 'Acting agent; required to touch a claim held by someone (default: \$BACKLOG_AGENT).',
    valueHelp: 'agent',
  );

  String? get optionalAgent => args.option('as') ?? context.environment['BACKLOG_AGENT'];

  String get agent => optionalAgent ?? (throw UsageException('Say who you are: --as <agent> or BACKLOG_AGENT.', usage));

  String singleArgument(String name) {
    if (args.rest.length != 1) throw UsageException('Expected exactly one $name.', usage);
    return args.rest.single;
  }

  void line([String text = '']) => context.out.writeln(text);

  void lines(Iterable<String> texts) => texts.forEach(line);

  void emitJson(Object? value) => line(const JsonEncoder.withIndent('  ').convert(value));

  /// Prints items as JSON or aligned rows.
  void emitItems(List<PlannedItem> items) =>
      json ? emitJson([for (final item in items) JsonOutput.item(item)]) : lines(TextOutput.rows(items));

  /// Re-reads the item (unless [snapshot] is given) so that the output
  /// includes derived state.
  Future<void> emitItem(
    Backlog backlog,
    ItemId id, {
    bool detail = false,
    String? message,
    BacklogSnapshot? snapshot,
  }) async {
    snapshot ??= await backlog.planning.snapshot();
    final planned = snapshot[id]!;
    final path = await backlog.items.locationOf(id);
    if (json) {
      emitJson(JsonOutput.item(planned, path: path, withBody: detail));
    } else if (detail) {
      lines(TextOutput.detail(planned, snapshot, path: path));
    } else {
      if (message != null) line(message);
      lines(TextOutput.rows([planned]));
    }
  }
}
