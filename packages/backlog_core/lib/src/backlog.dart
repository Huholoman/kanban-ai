import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'claims/application/claim_service.dart';
import 'dispatch/domain/action_run.dart';
import 'history/application/history_service.dart';
import 'infrastructure/backlog_layout.dart';
import 'items/application/item_service.dart';
import 'items/domain/item_id.dart';
import 'planning/application/planning_service.dart';
import 'planning/infrastructure/git_branch_changes.dart';
import 'planning/infrastructure/git_branch_heads.dart';
import 'presets/domain/init_preset.dart';
import 'presets/infrastructure/built_in_presets.dart';
import 'shared/clock.dart';
import 'shared/errors.dart';
import 'storage/domain/backlog_storage.dart';
import 'storage/infrastructure/file_backlog_storage.dart';
import 'validation/application/lint_fixes.dart';
import 'validation/application/linter.dart';
import 'views/application/view_service.dart';
import 'views/infrastructure/yaml_views.dart';
import 'workflow/domain/dispatcher_config.dart';
import 'workflow/domain/workflow.dart';
import 'workflow/domain/workflow_source.dart';
import 'workflow/infrastructure/yaml_workflow.dart';

/// Composition root: one backlog wired to the adapters of its
/// [BacklogStorage].
///
/// Adapters (CLI, server, app) talk to the services exposed here and never
/// touch files themselves.
final class Backlog {
  Backlog._({
    required this.storage,
    required this.configuration,
    required this.workflow,
    required this.revision,
    required this.items,
    required this.history,
    required this.planning,
    required this.claims,
    required this.views,
    required this.linter,
  });

  /// Opens the backlog folder at [root] ([FileBacklogStorage]). With
  /// [cacheItems] (long-running processes such as the server) parsed item
  /// files are kept in memory and only changed files are read again; claims
  /// are always read fresh.
  static Future<Backlog> open(
    String root, {
    Clock clock = const SystemClock(),
    IdGenerator? ids,
    bool cacheItems = false,
  }) => connect(
    FileBacklogStorage(root, cacheItems: cacheItems),
    clock: clock,
    ids: ids,
  );

  /// Opens the backlog kept in [storage]: reads its configuration and wires
  /// the services to the stores of that workflow.
  static Future<Backlog> connect(BacklogStorage storage, {Clock clock = const SystemClock(), IdGenerator? ids}) async {
    final configuration = storage.configuration;
    final loaded = await configuration.load();
    final workflow = loaded.workflow;
    final stores = storage.stores(workflow);
    final root = storage.root;
    final dispatcher = workflow.dispatcher;
    final repositories = [
      ?dispatcher?.newWorktrees?.resolveRepo(root),
      for (final worktree in dispatcher?.worktrees ?? const <WorktreeDefinition>[]) worktree.resolvePath(root),
      root,
    ];
    final planning = PlanningService(
      items: stores.items,
      claims: stores.claims,
      workflow: workflow,
      clock: clock,
      branches: GitBranchHeads(repositories),
      changes: GitBranchChanges(repositories, base: dispatcher?.base ?? 'main'),
    );

    final items = ItemService(
      repository: stores.items,
      workflow: workflow,
      ids: ids ?? RandomIdGenerator(prefix: workflow.idPrefix, length: workflow.idLength),
      clock: clock,
    );
    return Backlog._(
      storage: storage,
      configuration: configuration,
      workflow: workflow,
      revision: loaded.revision,
      items: items,
      history: HistoryService(items: items, revisions: stores.revisions, decode: stores.decode, clock: clock),
      planning: planning,
      claims: ClaimService(
        items: stores.items,
        claims: stores.claims,
        planning: planning,
        workflow: workflow,
        clock: clock,
      ),
      views: ViewService(views: stores.views, planning: planning),
      linter: Linter(
        items: stores.items,
        claims: stores.claims,
        views: stores.views,
        workflow: workflow,
        clock: clock,
        root: root,
        directoryExists: (path) => Directory(path).exists(),
        programExists: programOnPath,
      ),
    );
  }

  /// Whether [program] can be started: an existing file when it contains a
  /// slash, else found in one of the `PATH` folders.
  static Future<bool> programOnPath(String program) async {
    if (program.contains('/')) return File(program).exists();
    final path = Platform.environment['PATH'] ?? '';
    for (final folder in path.split(Platform.isWindows ? ';' : ':')) {
      if (folder.isNotEmpty && await File(p.join(folder, program)).exists()) return true;
    }
    return false;
  }

  /// Creates the folder structure with a default configuration and views.
  static Future<BacklogLayout> init(String root, {String idPrefix = 'T'}) async =>
      (await create(root, idPrefix: idPrefix)).layout;

  /// Creates the folder structure from [preset] (default: the built-in
  /// `default`): `backlog.yaml`, `views/`, `items/`, `docs/` and a
  /// `.gitignore` (unless there is one). Its placeholders get [idPrefix]
  /// (default `T`), the project's name (the folder, or its parent for a
  /// folder named `backlog`), [repo], the code repository relative to
  /// [root] (default `..`), and its folder name. A given [idPrefix] also replaces the prefix of
  /// a preset that names its own. Nothing is written when the configuration
  /// or a view does not parse.
  static Future<BacklogCreation> create(String root, {String? idPrefix, InitPreset? preset, String repo = '..'}) async {
    final layout = BacklogLayout(root);
    final config = File(layout.configFile);
    if (await config.exists()) {
      throw InvalidInputException('${layout.configFile} already exists.');
    }
    final name = p.basename(layout.root);
    final rendered = (preset ?? builtInPresets.first).render({
      'prefix': idPrefix ?? 'T',
      'project': name == 'backlog' ? p.basename(p.dirname(layout.root)) : name,
      'repo': repo,
      'repo_name': p.basename(p.normalize(p.join(layout.root, repo))),
    });
    var template = rendered.config;
    if (idPrefix != null) template = _withPrefix(template, idPrefix);
    final workflow = parseWorkflowYaml(template, origin: '${rendered.name} preset'); // fails early on an invalid prefix
    for (final MapEntry(key: id, value: yaml) in rendered.views.entries) {
      try {
        parseViewYaml(id, yaml);
      } on ConfigurationException catch (error) {
        throw ConfigurationException('View $id of the ${rendered.name} preset: ${error.message}');
      }
    }

    await Directory(layout.itemsDir).create(recursive: true);
    await Directory(layout.docsDir).create(recursive: true);
    await Directory(layout.viewsDir).create(recursive: true);
    await config.writeAsString(template);
    await File(p.join(layout.itemsDir, '.gitkeep')).writeAsString('');
    await File(p.join(layout.docsDir, '.gitkeep')).writeAsString('');
    for (final MapEntry(key: id, value: yaml) in rendered.views.entries) {
      await File(p.join(layout.viewsDir, '$id.yaml')).writeAsString(yaml);
    }
    final gitignore = File(p.join(layout.root, '.gitignore'));
    if (!await gitignore.exists()) {
      await gitignore.writeAsString('# claim locks are machine-local\n.locks/\n*.tmp\n*.stale\n');
    }
    return BacklogCreation(layout, preset: rendered, idPrefix: workflow.idPrefix);
  }

  /// [yaml] with `id.prefix` set to [prefix], keeping comments and layout.
  static String _withPrefix(String yaml, String prefix) {
    final editor = YamlEditor(yaml);
    final id = editor.parseAt(['id'], orElse: () => wrapAsYamlNode(null));
    if (id is YamlMap) {
      if (id['prefix'] == prefix) return yaml;
      editor.update(['id', 'prefix'], prefix);
    } else if (editor.parseAt([], orElse: () => wrapAsYamlNode(null)) is YamlMap) {
      editor.update(['id'], {'prefix': prefix});
    } else {
      return yaml;
    }
    return editor.toString();
  }

  /// Why the backlog at [root] cannot be opened (missing folder, no or a
  /// broken `backlog.yaml`), or null when it opens.
  static Future<String?> problem(String root) async {
    if (!await Directory(root).exists()) return 'Folder ${BacklogLayout(root).root} does not exist.';
    try {
      await open(root);
      return null;
    } on BacklogException catch (error) {
      return error.message;
    }
  }

  /// See [BacklogLayout.locate].
  static String? locate(String start) => BacklogLayout.locate(start);

  /// Where the backlog is kept.
  final BacklogStorage storage;

  /// Where [workflow] comes from; edits made through it apply to backlogs
  /// opened afterwards.
  final WorkflowSource configuration;

  final Workflow workflow;

  /// The revision of the configuration [workflow] was read from.
  final WorkflowRevision revision;

  /// Whether the configuration changed since this backlog was opened (then
  /// open it again to apply the change).
  Future<bool> get isStale async => await configuration.revision() != revision;

  final ItemService items;

  /// Histories of items (who changed what when), from the backlog's git
  /// repository and the discussions.
  final HistoryService history;
  final PlanningService planning;
  final ClaimService claims;
  final ViewService views;
  final Linter linter;

  /// The folder the backlog belongs to (see [BacklogStorage.root]).
  String get root => storage.root;

  /// Requests to run actions, for a server's dispatcher to pick up
  /// (`backlog action`).
  ActionRequests get actionRequests => storage.actionRequests;

  /// The fixes `backlog config` offers for lint issues.
  LintFixer get lintFixer => LintFixer(items: items, claims: claims, workflow: workflow);
}

/// What [Backlog.create] made: where, from which preset (its placeholders
/// filled) and the id prefix of the new backlog.
final class BacklogCreation {
  const BacklogCreation(this.layout, {required this.preset, required this.idPrefix});

  final BacklogLayout layout;
  final InitPreset preset;
  final String idPrefix;
}
