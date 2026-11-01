import '../../claims/infrastructure/file_system_claim_store.dart';
import '../../dispatch/domain/action_run.dart';
import '../../dispatch/infrastructure/action_files.dart';
import '../../history/infrastructure/git_item_revisions.dart';
import '../../infrastructure/backlog_layout.dart';
import '../../items/infrastructure/file_system_item_repository.dart';
import '../../items/infrastructure/markdown_item_codec.dart';
import '../../views/infrastructure/yaml_views.dart';
import '../../workflow/domain/workflow.dart';
import '../../workflow/domain/workflow_source.dart';
import '../../workflow/infrastructure/file_workflow_source.dart';
import '../domain/backlog_storage.dart';

/// A backlog folder: `backlog.yaml`, Markdown items with YAML front matter,
/// claim locks in `.locks/`, views in `views/`, action requests and the git
/// history of the item files.
///
/// With [cacheItems] (long-running processes such as the server) parsed item
/// files are kept in memory and only changed files are read again (see
/// [FileSystemItemRepository]); claims are always read fresh.
final class FileBacklogStorage implements BacklogStorage {
  FileBacklogStorage(String root, {this.cacheItems = false}) : layout = BacklogLayout(root);

  final BacklogLayout layout;
  final bool cacheItems;

  @override
  String get root => layout.root;

  @override
  late final WorkflowSource configuration = FileWorkflowSource(layout);

  @override
  ActionRequests get actionRequests => FileActionRequests(layout);

  @override
  BacklogStores stores(Workflow workflow) {
    final codec = MarkdownItemCodec(
      ItemDefaults(type: workflow.defaultType, status: workflow.defaultStatus, priority: workflow.defaultPriority),
    );
    return BacklogStores(
      items: FileSystemItemRepository(layout, codec, cache: cacheItems),
      claims: FileSystemClaimStore(layout, defaultLease: workflow.claimLease),
      views: YamlViewRepository(layout),
      revisions: const GitItemRevisions(),
      decode: codec.decode,
    );
  }

  @override
  String displayLocation(String location) => layout.relative(location);
}
