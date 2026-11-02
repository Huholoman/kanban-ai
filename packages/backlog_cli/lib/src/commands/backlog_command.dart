import 'dart:convert';
import 'dart:io';

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

  /// The backlog folder: `--dir`, `\$KANBAN_AI_DIR` or found from the current folder.
  String get backlogRoot {
    final explicit = globalResults!.option('dir') ?? toolVariable(context.environment, 'DIR');
    return explicit != null
        ? p.normalize(p.join(context.cwd, explicit))
        : Backlog.locate(context.cwd) ??
              (throw const NotFoundException(
                'No backlog found here or in any parent folder (looked for backlog.yaml and backlog/backlog.yaml). '
                'Use --dir, KANBAN_AI_DIR or `kanban-ai init`.',
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
        ? 'Agent name, e.g. the worktree (default: \$KANBAN_AI_AGENT).'
        : 'Acting agent; required to touch a claim held by someone (default: \$KANBAN_AI_AGENT).',
    valueHelp: 'agent',
  );

  String? get optionalAgent => args.option('as') ?? toolVariable(context.environment, 'AGENT');

  String get agent =>
      optionalAgent ?? (throw UsageException('Say who you are: --as <agent> or KANBAN_AI_AGENT.', usage));

  /// `--file <path>`: the command's text from a file (relative to the
  /// current folder; `-` reads standard input) instead of the arguments —
  /// for long, multi-line texts an agent writes with its file tools.
  void addTextFileOption() => argParser.addOption(
    'file',
    abbr: 'F',
    help: 'Read the text from a file (- reads standard input), e.g. a long, multi-line one.',
    valueHelp: 'path',
  );

  /// The text of the command: from `--file` ([addTextFileOption]), else the
  /// [words] joined (a single `-` reads standard input).
  Future<String> textOf(List<String> words) async {
    final file = args.option('file');
    if (file != null && words.isNotEmpty) throw UsageException('Give the text or --file, not both.', usage);
    if (file == null && words.length == 1 && words.single == '-' || file == '-') {
      return (context.readInput ?? (throw UsageException('No standard input to read.', usage)))();
    }
    if (file == null) return words.join(' ');
    final path = p.normalize(p.join(context.cwd, file));
    try {
      return await File(path).readAsString();
    } on FileSystemException catch (error) {
      throw InvalidInputException('Cannot read $path: ${error.osError?.message ?? error.message}.');
    }
  }

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
    final attachments = detail ? await backlog.items.attachmentsOf(id) : null;
    if (json) {
      emitJson(JsonOutput.item(planned, path: path, withBody: detail, attachments: attachments));
    } else if (detail) {
      lines(TextOutput.detail(planned, snapshot, path: path, attachments: attachments!));
    } else {
      if (message != null) line(message);
      lines(TextOutput.rows([planned]));
    }
  }
}
