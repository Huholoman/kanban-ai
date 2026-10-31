import 'dart:io';

import 'package:path/path.dart' as p;

import 'claims/application/claim_service.dart';
import 'claims/infrastructure/file_system_claim_store.dart';
import 'dispatch/domain/action_run.dart';
import 'dispatch/infrastructure/action_files.dart';
import 'infrastructure/backlog_layout.dart';
import 'items/application/item_service.dart';
import 'items/domain/item_id.dart';
import 'items/infrastructure/file_system_item_repository.dart';
import 'items/infrastructure/markdown_item_codec.dart';
import 'planning/application/planning_service.dart';
import 'planning/infrastructure/git_branch_heads.dart';
import 'shared/clock.dart';
import 'shared/errors.dart';
import 'validation/application/linter.dart';
import 'views/application/view_service.dart';
import 'views/infrastructure/yaml_views.dart';
import 'workflow/domain/dispatcher_config.dart';
import 'workflow/domain/workflow.dart';
import 'workflow/infrastructure/yaml_workflow.dart';

/// Composition root: one backlog folder wired to its file-system adapters.
///
/// Adapters (CLI, server, app) talk to the services exposed here and never
/// touch files themselves.
final class Backlog {
  Backlog._({
    required this.layout,
    required this.workflow,
    required this.items,
    required this.planning,
    required this.claims,
    required this.views,
    required this.linter,
  });

  /// Opens the backlog at [root]. With [cacheItems] (long-running processes
  /// such as the server) parsed item files are kept in memory and only
  /// changed files are read again (see [FileSystemItemRepository]); claims
  /// are always read fresh.
  static Future<Backlog> open(
    String root, {
    Clock clock = const SystemClock(),
    IdGenerator? ids,
    bool cacheItems = false,
  }) async {
    final layout = BacklogLayout(root);
    final config = File(layout.configFile);
    if (!await config.exists()) {
      throw NotFoundException('No ${BacklogLayout.configFileName} in ${layout.root}; run `backlog init` first.');
    }
    final workflow = parseWorkflowYaml(await config.readAsString(), origin: layout.configFile);

    final itemRepository = FileSystemItemRepository(
      layout,
      MarkdownItemCodec(
        ItemDefaults(type: workflow.defaultType, status: workflow.defaultStatus, priority: workflow.defaultPriority),
      ),
      cache: cacheItems,
    );
    final claimStore = FileSystemClaimStore(layout, defaultLease: workflow.claimLease);
    final viewRepository = YamlViewRepository(layout);
    final dispatcher = workflow.dispatcher;
    final planning = PlanningService(
      items: itemRepository,
      claims: claimStore,
      workflow: workflow,
      clock: clock,
      branches: GitBranchHeads([
        ?dispatcher?.newWorktrees?.resolveRepo(layout.root),
        for (final worktree in dispatcher?.worktrees ?? const <WorktreeDefinition>[]) worktree.resolvePath(layout.root),
        layout.root,
      ]),
    );

    return Backlog._(
      layout: layout,
      workflow: workflow,
      items: ItemService(
        repository: itemRepository,
        workflow: workflow,
        ids: ids ?? RandomIdGenerator(prefix: workflow.idPrefix, length: workflow.idLength),
        clock: clock,
      ),
      planning: planning,
      claims: ClaimService(
        items: itemRepository,
        claims: claimStore,
        planning: planning,
        workflow: workflow,
        clock: clock,
      ),
      views: ViewService(views: viewRepository, planning: planning),
      linter: Linter(
        items: itemRepository,
        claims: claimStore,
        views: viewRepository,
        workflow: workflow,
        clock: clock,
        root: layout.root,
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
  static Future<BacklogLayout> init(String root, {String idPrefix = 'T'}) async {
    final layout = BacklogLayout(root);
    final config = File(layout.configFile);
    if (await config.exists()) {
      throw InvalidInputException('${layout.configFile} already exists.');
    }
    final template = workflowTemplate(idPrefix: idPrefix);
    parseWorkflowYaml(template); // fails early on an invalid prefix

    await Directory(layout.itemsDir).create(recursive: true);
    await Directory(layout.docsDir).create(recursive: true);
    await Directory(layout.viewsDir).create(recursive: true);
    await config.writeAsString(template);
    await File(p.join(layout.itemsDir, '.gitkeep')).writeAsString('');
    await File(p.join(layout.docsDir, '.gitkeep')).writeAsString('');
    for (final MapEntry(key: id, value: yaml) in defaultViews.entries) {
      await File(p.join(layout.viewsDir, '$id.yaml')).writeAsString(yaml);
    }
    final gitignore = File(p.join(layout.root, '.gitignore'));
    if (!await gitignore.exists()) {
      await gitignore.writeAsString('# claim locks are machine-local\n.locks/\n*.tmp\n*.stale\n');
    }
    return layout;
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

  final BacklogLayout layout;
  final Workflow workflow;
  final ItemService items;
  final PlanningService planning;
  final ClaimService claims;
  final ViewService views;
  final Linter linter;

  String get root => layout.root;

  /// Requests to run actions, for a server's dispatcher to pick up
  /// (`backlog action`).
  ActionRequests get actionRequests => FileActionRequests(layout);
}
