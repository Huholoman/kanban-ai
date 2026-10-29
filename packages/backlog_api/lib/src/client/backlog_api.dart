import '../model/item_dto.dart';
import '../model/misc_dto.dart';
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

  Future<ViewResultDto> view(String id);

  Future<ViewSummaryDto> updateView(String id, ViewUpdateRequest request);

  Future<List<LintIssueDto>> lint();

  /// Notifications about changed files; reconnects while listened to.
  Stream<BacklogChangeEvent> changes();
}

/// URL paths of the API, shared by the server and the client.
abstract final class ApiPaths {
  static const workflow = '/api/workflow';
  static const items = '/api/items';
  static const views = '/api/views';
  static const lint = '/api/lint';
  static const events = '/api/events';
  static const health = '/api/health';

  static String item(String reference) => '$items/${Uri.encodeComponent(reference)}';

  static String itemAction(String reference, String action) => '${item(reference)}/$action';

  static String view(String id) => '$views/${Uri.encodeComponent(id)}';
}
