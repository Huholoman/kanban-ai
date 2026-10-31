import '../model/agent_log_update_dto.dart';
import '../model/dispatch_dto.dart';
import '../model/item_dto.dart';
import '../model/misc_dto.dart';
import '../model/project_dto.dart';
import '../model/requests.dart';
import '../model/view_dto.dart';
import '../model/workflow_dto.dart';

/// What a client can do with a backlog. Implemented over HTTP by
/// [HttpBacklogApi]; UI code depends on this interface so that tests can
/// swap in a fake.
abstract interface class BacklogApi {
  Future<WorkflowDto> workflow();

  /// Items in the default order; finished ones only with [includeDone].
  Future<List<ItemDto>> items({bool includeDone = false});

  /// [reference] may be a shortened id.
  Future<ItemDetailDto> item(String reference);

  Future<ItemDetailDto> createItem(NewItemRequest request);

  Future<ItemDetailDto> updateItem(String reference, ItemUpdateRequest request);

  Future<ItemDetailDto> claim(String reference, ClaimRequest request);

  Future<ItemDetailDto> release(String reference, ClaimRequest request);

  Future<ItemDetailDto> complete(String reference, ClaimRequest request);

  Future<List<ViewSummaryDto>> views();

  /// Runs view [id]; [groupBy] regroups it for this request only ('' for
  /// ungrouped).
  Future<ViewResultDto> view(String id, {String? groupBy});

  Future<ViewSummaryDto> updateView(String id, ViewUpdateRequest request);

  Future<ViewSummaryDto> createView(NewViewRequest request);

  Future<List<LintIssueDto>> lint();

  /// The dispatcher's plan; [DispatchDto.off] without a dispatcher.
  Future<DispatchDto> dispatch();

  /// Starts an agent for the ready item [reference] in the first free
  /// worktree (also in manual mode) and returns the new plan.
  Future<DispatchDto> startAgent(String reference);

  /// Stops the agent working on [reference] and returns the new plan.
  Future<DispatchDto> stopAgent(String reference);

  /// The end of the log of the agent of [reference] (running or last).
  Future<AgentLogDto> agentLog(String reference, {int lines = 100});

  /// Follows the log of the agent of [reference] live: first its last
  /// [lines] readable lines (also of an ended run, or none yet), then what
  /// is appended, a new run's log (reset) and the end of the run; reconnects
  /// while listened to.
  Stream<AgentLogUpdateDto> followAgentLog(String reference, {int lines = 200});

  /// Notifications about changed files and, with [BacklogChangeEvent.isDispatch],
  /// about a changed dispatcher plan; reconnects while listened to.
  Stream<BacklogChangeEvent> changes();
}

/// The backlogs a server serves and a [BacklogApi] for each of them.
abstract interface class ProjectsApi {
  /// Registered projects in the registry's order; the first one is the
  /// default project answered on the unprefixed paths.
  Future<List<ProjectDto>> projects();

  /// The API of one project (paths under `/api/p/<id>`).
  BacklogApi project(String id);
}

/// URL paths of the API, shared by the server and the client.
///
/// Every path except [health] and [projects] also exists per project under
/// [projectPrefix] (`/api/p/<id>/items`, …); the unprefixed paths address
/// the default project.
abstract final class ApiPaths {
  static const workflow = '/api/workflow';
  static const items = '/api/items';
  static const views = '/api/views';
  static const lint = '/api/lint';
  static const dispatch = '/api/dispatch';
  static const dispatchStart = '/api/dispatch/start';
  static const dispatchStop = '/api/dispatch/stop';
  static const events = '/api/events';
  static const health = '/api/health';
  static const projects = '/api/projects';

  static String projectPrefix(String id) => '/api/p/${Uri.encodeComponent(id)}';

  /// [path] (one of the unprefixed paths above) inside project [id].
  static String inProject(String id, String path) =>
      path.startsWith('/api/') ? '${projectPrefix(id)}${path.substring(4)}' : path;

  static String item(String reference) => '$items/${Uri.encodeComponent(reference)}';

  static String itemAction(String reference, String action) => '${item(reference)}/$action';

  static String agentLog(String reference) => '$dispatch/log/${Uri.encodeComponent(reference)}';

  /// WebSocket following the agent log of [reference].
  static String agentLogLive(String reference) => '${agentLog(reference)}/live';

  static String view(String id) => '$views/${Uri.encodeComponent(id)}';
}
