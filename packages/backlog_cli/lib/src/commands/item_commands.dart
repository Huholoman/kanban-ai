import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;

import '../where.dart';
import 'backlog_command.dart';

final class InitCommand extends BacklogCommand {
  InitCommand(super.context) {
    argParser.addOption('prefix', defaultsTo: 'T', help: 'Prefix of item ids.');
  }

  @override
  String get name => 'init';

  @override
  String get description => 'Create a backlog (backlog.yaml, items/, views/, docs/) in a folder.';

  @override
  String get invocation => 'backlog init [folder]';

  @override
  Future<int> run() async {
    final folder = args.rest.isEmpty ? '.' : args.rest.single;
    final layout = await Backlog.init(p.join(context.cwd, folder), idPrefix: args.option('prefix')!);
    json ? emitJson({'root': layout.root}) : line('Created backlog in ${layout.root}');
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
    await emitItem(backlog, item.id, message: 'Created ${await backlog.items.locate(item.id.value)}');
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
    final item = await backlog.items.get(singleArgument('item id'));
    await emitItem(backlog, item.id, detail: true);
    return 0;
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
