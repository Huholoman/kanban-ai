import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;

import 'backlog_command.dart';

/// `backlog projects [list | add [<path>] | remove <id> | pin <id> | unpin <id>]`:
/// the registry of backlogs that `backlog-server` hosts.
final class ProjectsCommand extends BacklogCommand {
  ProjectsCommand(super.context) {
    argParser
      ..addOption(
        'projects',
        valueHelp: 'file',
        help: 'Registry file (default: \$BACKLOG_PROJECTS, else \$XDG_CONFIG_HOME/kanban-ai/projects.yaml).',
      )
      ..addOption('id', help: 'add: project id used in URLs (default: slug of the project folder).')
      ..addOption('name', help: 'add: display name (default: the project folder).');
  }

  @override
  String get name => 'projects';

  @override
  String get description =>
      'List, add, remove, pin or unpin the backlogs backlog-server hosts (the first one is the default project; '
      'the board lists pinned ones first).';

  @override
  String get invocation => 'backlog projects [list | add [<path>] | remove <id> | pin <id> | unpin <id>]';

  ProjectService get _service =>
      projectService(args.option('projects')) ??
      (throw UsageException('No registry location: set HOME or pass --projects <file>.', usage));

  @override
  Future<int> run() async {
    final [action, ...rest] = args.rest.isEmpty ? ['list'] : args.rest;
    if (action != 'add' && (args.option('id') != null || args.option('name') != null)) {
      throw UsageException('--id and --name only go with `add`.', usage);
    }
    switch (action) {
      case 'list' when rest.isEmpty:
        return _list();
      case 'add' when rest.length <= 1:
        return _add(rest.firstOrNull);
      case 'remove' when rest.length == 1:
        final entry = await _service.remove(rest.single);
        json ? emitJson(await _describe(entry)) : line('Removed ${entry.id} (${entry.path}).');
        return 0;
      case 'pin' || 'unpin' when rest.length == 1:
        final entry = await _service.setPinned(rest.single, action == 'pin');
        json ? emitJson(await _describe(entry)) : line('${entry.pinned ? 'Pinned' : 'Unpinned'} ${entry.id}.');
        return 0;
      default:
        throw UsageException('Unknown or incomplete `projects ${args.rest.join(' ')}`.', usage);
    }
  }

  Future<int> _list() async {
    final service = _service;
    final registry = await service.registry();
    if (json) {
      emitJson([
        for (final entry in registry.entries) await _describe(entry, isDefault: entry == registry.defaultProject),
      ]);
      return 0;
    }
    if (registry.isEmpty) {
      line('No projects in ${service.location}; register one with `backlog projects add [<path>]`.');
      return 0;
    }
    final idWidth = registry.entries.map((e) => e.id.length).reduce((a, b) => a > b ? a : b);
    final nameWidth = registry.entries.map((e) => e.displayName.length).reduce((a, b) => a > b ? a : b);
    for (final entry in registry.entries) {
      final error = await Backlog.problem(entry.path);
      line(
        '${entry.id.padRight(idWidth)}  ${entry.displayName.padRight(nameWidth)}  ${entry.path}'
        '${entry == registry.defaultProject ? '  (default)' : ''}${entry.pinned ? '  (pinned)' : ''}${error == null ? '' : '\n  error: $error'}',
      );
    }
    return 0;
  }

  Future<int> _add(String? path) async {
    final String root;
    if (path == null) {
      root = backlogRoot;
    } else {
      final dir = p.normalize(p.join(context.cwd, path));
      final nested = p.join(dir, 'backlog');
      root =
          !File(p.join(dir, BacklogLayout.configFileName)).existsSync() &&
              File(p.join(nested, BacklogLayout.configFileName)).existsSync()
          ? nested
          : dir;
    }
    await Backlog.open(root, clock: context.clock); // only real, readable backlogs
    final entry = await _service.add(root, id: args.option('id'), name: args.option('name'));
    json ? emitJson(await _describe(entry)) : line('Added ${entry.id} (${entry.path}) to ${_service.location}.');
    return 0;
  }

  Future<Map<String, Object?>> _describe(ProjectEntry entry, {bool? isDefault}) async => {
    'id': entry.id,
    'name': entry.displayName,
    'path': entry.path,
    'default': ?isDefault,
    'pinned': entry.pinned,
    'error': await Backlog.problem(entry.path),
  };
}
