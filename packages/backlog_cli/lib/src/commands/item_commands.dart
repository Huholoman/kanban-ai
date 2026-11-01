import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;

import '../render/json_output.dart';
import '../render/text_output.dart';
import '../where.dart';
import 'backlog_command.dart';

final class InitCommand extends BacklogCommand {
  InitCommand(super.context) {
    argParser
      ..addOption('prefix', help: 'Prefix of item ids (default: T, or what the preset or --from backlog says).')
      ..addOption(
        'preset',
        help: 'Start from this preset: a name (see --list-presets) or a folder with backlog.yaml.',
        valueHelp: 'name|folder',
      )
      ..addOption(
        'from',
        help: 'Copy the configuration and views (not the items) of this backlog.',
        valueHelp: 'backlog',
      )
      ..addOption(
        'repo',
        help: 'The code repository, for the dispatcher of presets that name it (default: the parent folder).',
        valueHelp: 'folder',
      )
      ..addOption(
        'agents-file',
        help:
            'Append the preset\'s guide for agents to this file (e.g. CLAUDE.md or AGENTS.md of the repository) '
            'instead of printing it.',
        valueHelp: 'file',
      )
      ..addFlag('list-presets', negatable: false, help: 'List the presets and exit.')
      ..addFlag(
        'register',
        defaultsTo: true,
        help: 'Add the new backlog to the project registry (see `backlog projects`).',
      );
  }

  @override
  String get name => 'init';

  @override
  String get description =>
      'Create a backlog (backlog.yaml, items/, views/, docs/) in a folder, optionally from a preset.';

  @override
  String get invocation => 'backlog init [folder] [--preset name|folder | --from backlog] [--prefix X]';

  PresetCatalog get _catalog => PresetCatalog(userDir: PresetCatalog.userDirFor(context.environment));

  @override
  Future<int> run() async {
    if (args.flag('list-presets')) return _listPresets();
    if (args.rest.length > 1) throw UsageException('Expected at most one folder.', usage);
    if (args.option('preset') != null && args.option('from') != null) {
      throw UsageException('Give either --preset or --from.', usage);
    }
    final InitPreset? preset;
    if (args.option('from') case final from?) {
      final source = p.normalize(p.join(context.cwd, from));
      preset = await PresetCatalog.fromBacklog(Backlog.locate(source) ?? source);
    } else if (args.option('preset') case final name?) {
      preset = await _catalog.resolve(name, cwd: context.cwd, home: context.environment['HOME']);
    } else {
      preset = null;
    }
    final folder = args.rest.isEmpty ? '.' : args.rest.single;
    final root = p.normalize(p.join(context.cwd, folder));
    final repo = args.option('repo') == null
        ? '..'
        : p.relative(p.normalize(p.join(context.cwd, args.option('repo')!)), from: root);
    final created = await Backlog.create(root, idPrefix: args.option('prefix'), preset: preset, repo: repo);
    final layout = created.layout;

    ProjectEntry? project;
    String? registered;
    final registry = args.flag('register') ? projectService() : null;
    if (registry != null) {
      try {
        final (entry, added) = await registry.ensure(layout.root);
        project = entry;
        if (added) registered = 'Registered as project ${entry.id} in ${registry.location}';
      } on BacklogException catch (error) {
        context.err.writeln('warning: not registered in ${registry.location}: ${error.message}');
      }
    }

    final guide = created.preset.agentsGuide;
    String? guideFile;
    var guideWritten = false;
    if (guide != null && args.option('agents-file') != null) {
      guideFile = p.normalize(p.join(context.cwd, args.option('agents-file')!));
      guideWritten = await _appendGuide(guideFile, guide);
    }
    if (json) {
      emitJson({
        'root': layout.root,
        if (project != null) 'project': {'id': project.id, 'name': project.displayName},
        'preset': created.preset.name,
        'prefix': created.idPrefix,
        'agents_guide': guide,
        'agents_file': guideFile,
      });
      return 0;
    }
    lines([
      'Created backlog in ${layout.root}'
          '${preset == null ? '' : ' from ${args.option('from') != null ? 'the backlog ${preset.source}' : 'preset ${preset.name}'}'}'
          ' (ids ${created.idPrefix}-…)',
      ?registered,
    ]);
    if (guide == null) return 0;
    if (guideFile != null) {
      line(guideWritten ? 'Added the guide for agents to $guideFile.' : '$guideFile has the guide for agents already.');
    } else {
      line('');
      line('Add this guide for agents to CLAUDE.md / AGENTS.md of the repository (or use --agents-file):');
      line('');
      context.out.write(guide.endsWith('\n') ? guide : '$guide\n');
    }
    return 0;
  }

  /// Appends [guide] to [path] unless its first line is there already.
  static Future<bool> _appendGuide(String path, String guide) async {
    final file = File(path);
    final existing = await file.exists() ? await file.readAsString() : '';
    final heading = guide.trimLeft().split('\n').first.trim();
    if (heading.isNotEmpty && existing.split('\n').any((line) => line.trim() == heading)) return false;
    await file.parent.create(recursive: true);
    final separator = existing.isEmpty
        ? ''
        : (existing.endsWith('\n\n') ? '' : (existing.endsWith('\n') ? '\n' : '\n\n'));
    await file.writeAsString('$existing$separator${guide.trimLeft()}${guide.endsWith('\n') ? '' : '\n'}');
    return true;
  }

  Future<int> _listPresets() async {
    final presets = await _catalog.list();
    if (json) {
      emitJson([
        for (final preset in presets)
          {
            'name': preset.name,
            'description': preset.description,
            'source': preset.source,
            'agents_guide': preset.agentsGuide != null,
          },
      ]);
      return 0;
    }
    final width = presets.map((preset) => preset.name.length).fold(0, (a, b) => a > b ? a : b);
    for (final preset in presets) {
      final origin = preset.source == InitPreset.builtIn ? '' : '  (${preset.source})';
      line('${preset.name.padRight(width)}  ${preset.description}$origin');
    }
    return 0;
  }
}

final class NewCommand extends BacklogCommand {
  NewCommand(super.context) {
    argParser
      ..addOption('type', abbr: 't')
      ..addOption('status', abbr: 's')
      ..addOption('priority', abbr: 'p')
      ..addOption('milestone', abbr: 'm')
      ..addOption('parent')
      ..addMultiOption('depends-on', abbr: 'd', help: 'Repeat or separate by commas.')
      ..addMultiOption('related')
      ..addMultiOption('label', abbr: 'l')
      ..addMultiOption('doc')
      ..addMultiOption(
        'touches',
        help: 'Paths or globs in the code repository the work will change (repeat or separate by commas).',
        splitCommas: false,
      )
      ..addOption('assignee')
      ..addOption('branch')
      ..addOption('pr', help: 'Link to the pull request.')
      ..addOption('body', help: 'Markdown body.')
      ..addOption('body-file', help: 'Read the Markdown body from a file.');
  }

  @override
  String get name => 'new';

  @override
  String get description => 'Create an item.';

  @override
  String get invocation => 'backlog new <title> [options]';

  @override
  Future<int> run() async {
    final title = args.rest.join(' ');
    if (title.trim().isEmpty) throw UsageException('A title is required.', usage);
    final bodyFile = args.option('body-file');
    final body = bodyFile != null
        ? await File(p.join(context.cwd, bodyFile)).readAsString()
        : args.option('body') ?? '';

    final backlog = await openBacklog();
    final item = await backlog.items.create(
      NewItem(
        title: title,
        type: args.option('type'),
        status: args.option('status'),
        priority: args.option('priority'),
        milestone: args.option('milestone'),
        parent: args.option('parent'),
        dependsOn: args.multiOption('depends-on'),
        related: args.multiOption('related'),
        labels: args.multiOption('label'),
        docs: args.multiOption('doc'),
        touches: args.multiOption('touches').expand(FieldChange.splitList).toList(),
        assignee: args.option('assignee'),
        branch: args.option('branch'),
        pr: args.option('pr'),
        body: body,
      ),
    );
    await emitItem(backlog, item.id, message: 'Created ${await backlog.items.locationOf(item.id)}');
    return 0;
  }
}

final class ListCommand extends BacklogCommand {
  ListCommand(super.context) {
    argParser
      ..addMultiOption(
        'where',
        abbr: 'w',
        help: 'Condition: field=a,b  field!=a  field~text  field?  !field?',
        splitCommas: false,
      )
      ..addMultiOption('status', abbr: 's')
      ..addMultiOption('milestone', abbr: 'm')
      ..addMultiOption('label', abbr: 'l')
      ..addMultiOption('type', abbr: 't')
      ..addFlag('all', abbr: 'a', negatable: false, help: 'Include done items.');
  }

  @override
  String get name => 'list';

  @override
  List<String> get aliases => const ['ls'];

  @override
  String get description => 'List items (open ones unless --all), most urgent first.';

  @override
  Future<int> run() async {
    final backlog = await openBacklog();
    final filter = combineWhere(args.multiOption('where'), [
      for (final field in ['status', 'milestone', 'type'])
        if (args.multiOption(field).isNotEmpty) FieldIn(field, args.multiOption(field)),
      if (args.multiOption('label').isNotEmpty) FieldIn('labels', args.multiOption('label')),
      if (!args.flag('all') && args.multiOption('status').isEmpty) Not(FieldIn('category', ['done'])),
    ]);
    final snapshot = await backlog.planning.snapshot();
    emitItems(snapshot.items.where(filter.matches).toList());
    return 0;
  }
}

final class ShowCommand extends BacklogCommand {
  ShowCommand(super.context);

  @override
  String get name => 'show';

  @override
  String get description => 'Show an item with its relations, claim and body.';

  @override
  String get invocation => 'backlog show <id>';

  @override
  Future<int> run() async {
    final backlog = await openBacklog();
    final snapshot = await backlog.planning.snapshot();
    final id = ItemReference.resolve(singleArgument('item id'), snapshot.ids);
    await emitItem(backlog, id, detail: true, snapshot: snapshot);
    return 0;
  }
}

final class HistoryCommand extends BacklogCommand {
  HistoryCommand(super.context) {
    argParser.addOption(
      'only',
      help: 'Only some entries.',
      allowed: ItemHistory.filters,
      allowedHelp: {
        'status': 'creation and status changes',
        'fields': 'changes of fields and the description',
        'comments': 'the discussion',
        'runs': 'agents and actions the dispatcher ran',
      },
    );
  }

  @override
  String get name => 'history';

  @override
  String get description =>
      'Show who changed what and when: changes from the git history of the item file (and the uncommitted one), '
      'comments, and the agent and action runs of the dispatcher.';

  @override
  String get invocation => 'backlog history <id> [--only status|fields|comments|runs]';

  @override
  Future<int> run() async {
    final backlog = await openBacklog();
    final entries = await backlog.history.of(singleArgument('item id'), runs: _runs, only: args.option('only'));
    json ? emitJson([for (final entry in entries) JsonOutput.historyEntry(entry)]) : lines(TextOutput.history(entries));
    return 0;
  }

  /// The runs from the logs of the dispatcher, found by this backlog's id in
  /// the project registry; none when it is not registered.
  Future<List<RunRecord>> _runs(ItemId id) async {
    final service = projectService();
    if (service == null) return const [];
    final ProjectRegistry registry;
    try {
      registry = await service.registry();
    } on BacklogException {
      return const [];
    }
    final root = p.canonicalize(backlogRoot);
    final entry = registry.entries.where((entry) => p.canonicalize(entry.path) == root).firstOrNull;
    if (entry == null) return const [];
    final launcher = ProcessAgentLauncher(
      project: entry.id,
      backlog: openBacklog,
      stateDir: ProcessAgentLauncher.defaultStateDir(context.environment),
    );
    return launcher.runsOf(id);
  }
}

final class PathCommand extends BacklogCommand {
  PathCommand(super.context);

  @override
  String get name => 'path';

  @override
  String get description => 'Print the file of an item (to open or edit it).';

  @override
  String get invocation => 'backlog path <id>';

  @override
  Future<int> run() async {
    final backlog = await openBacklog();
    final path = await backlog.items.locate(singleArgument('item id'));
    json ? emitJson({'path': path}) : line(path ?? '');
    return 0;
  }
}

final class SetCommand extends BacklogCommand {
  SetCommand(super.context);

  @override
  String get name => 'set';

  @override
  String get description =>
      'Change fields: status=review  labels+=infra  depends_on-=T-7f3a  touches+=lib/a/  milestone=  (empty clears).';

  @override
  String get invocation => 'backlog set <id> <field=value>...';

  @override
  Future<int> run() async {
    if (args.rest.length < 2) throw UsageException('Expected an item id and at least one change.', usage);
    final changes = args.rest.skip(1).map(FieldChange.parse).toList();
    final backlog = await openBacklog();
    final item = await backlog.items.update(args.rest.first, changes);
    await emitItem(backlog, item.id, message: 'Updated ${item.id}');
    return 0;
  }
}

/// `backlog describe <id> (<text…> | --file f) [--section name]`: replaces
/// the item's description or one of its sections without editing its file
/// (agents cannot: it lies outside their worktree).
final class DescribeCommand extends BacklogCommand {
  DescribeCommand(super.context) {
    argParser.addOption(
      'section',
      abbr: 's',
      help: 'Replace only the content of the section "## <name>" (added when missing), e.g. "Acceptance criteria".',
      valueHelp: 'name',
    );
    addTextFileOption();
  }

  @override
  String get name => 'describe';

  @override
  String get description =>
      'Replace the description of an item (its body above ## Discussion) or one of its sections; the discussion '
      'stays.';

  @override
  String get invocation =>
      'backlog describe <id> ("<text>" | --file <path>) [--section "<name>"]   (text - or --file - reads standard input)';

  @override
  Future<int> run() async {
    if (args.rest.isEmpty || (args.rest.length < 2 && args.option('file') == null)) {
      throw UsageException('Expected an item id and the text (or --file).', usage);
    }
    final text = await textOf(args.rest.skip(1).toList());
    final section = args.option('section');
    final backlog = await openBacklog();
    final item = await backlog.items.describe(args.rest.first, text, section: section);
    await emitItem(
      backlog,
      item.id,
      detail: json,
      message: section == null ? 'Described ${item.id}.' : 'Replaced the section "$section" of ${item.id}.',
    );
    return 0;
  }
}
