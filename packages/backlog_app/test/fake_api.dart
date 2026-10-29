import 'dart:async';

import 'package:backlog_api/backlog_api.dart';

const _workflow = WorkflowDto(
  statuses: [
    StatusDto(id: 'backlog', category: StatusCategoryDto.open),
    StatusDto(id: 'todo', category: StatusCategoryDto.open, pickable: true),
    StatusDto(id: 'in-progress', category: StatusCategoryDto.active),
    StatusDto(id: 'done', category: StatusCategoryDto.done),
  ],
  priorities: ['p0', 'p1', 'p2', 'p3'],
  types: ['task', 'epic', 'bug'],
  defaultStatus: 'backlog',
  defaultPriority: 'p2',
  defaultType: 'task',
);

ItemDto item(
  String id, {
  String status = 'todo',
  String priority = 'p2',
  String? body,
  List<String> labels = const [],
  String type = 'task',
  String? parent,
  List<String> dependsOn = const [],
}) => ItemDto(
  id: id,
  title: 'Item $id',
  type: type,
  status: status,
  category: _workflow.categoryOf(status),
  priority: priority,
  parent: parent,
  dependsOn: dependsOn,
  labels: labels,
  body: body,
);

/// In-memory [BacklogApi]: a kanban `board` grouped by status and a `list`
/// view, edits recorded in [updates].
final class FakeBacklogApi implements BacklogApi {
  FakeBacklogApi(Iterable<ItemDto> items) : items_ = {for (final item in items) item.id: item};

  final Map<String, ItemDto> items_;
  final updates = <(String, ItemUpdateRequest)>[];
  final claims = <(String, String, ClaimRequest)>[];
  final _changes = StreamController<BacklogChangeEvent>.broadcast();
  int viewLoads = 0;
  Object? failNextUpdate;

  /// Simulates an agent editing a file on disk.
  void externalChange(ItemDto item) {
    items_[item.id] = item;
    _changes.add(BacklogChangeEvent(['items/${item.id}.md']));
  }

  @override
  Future<WorkflowDto> workflow() async => _workflow;

  @override
  Future<List<ItemDto>> items({bool includeDone = false}) async =>
      items_.values.where((i) => includeDone || !i.isDone).toList();

  @override
  Future<ItemDetailDto> item(String reference) async {
    final found = items_[reference];
    if (found == null) throw BacklogApiException(404, 'not_found', 'No item "$reference".');
    return ItemDetailDto(item: found);
  }

  @override
  Future<ItemDetailDto> createItem(NewItemRequest request) async {
    final id = 'T-${items_.length + 1}';
    items_[id] = ItemDto(
      id: id,
      title: request.title,
      type: request.type ?? 'task',
      status: request.status ?? 'backlog',
      category: _workflow.categoryOf(request.status ?? 'backlog'),
      priority: request.priority ?? 'p2',
      body: request.body,
    );
    return ItemDetailDto(item: items_[id]!);
  }

  @override
  Future<ItemDetailDto> updateItem(String reference, ItemUpdateRequest request) async {
    if (failNextUpdate case final error?) {
      failNextUpdate = null;
      throw error;
    }
    updates.add((reference, request));
    var current = items_[reference]!;
    for (final change in request.changes) {
      final [field, value] = change.split('=');
      current = _with(current, status: field == 'status' ? value : null, priority: field == 'priority' ? value : null);
    }
    if (request.body != null) current = _with(current, body: request.body);
    items_[reference] = current;
    return ItemDetailDto(item: current);
  }

  @override
  Future<ItemDetailDto> claim(String reference, ClaimRequest request) => _claim('claim', reference, request);

  @override
  Future<ItemDetailDto> release(String reference, ClaimRequest request) => _claim('release', reference, request);

  @override
  Future<ItemDetailDto> complete(String reference, ClaimRequest request) async {
    claims.add(('done', reference, request));
    items_[reference] = _with(items_[reference]!, status: 'done');
    return ItemDetailDto(item: items_[reference]!);
  }

  Future<ItemDetailDto> _claim(String action, String reference, ClaimRequest request) async {
    claims.add((action, reference, request));
    return ItemDetailDto(item: items_[reference]!);
  }

  /// Section of each view, as `PATCH /api/views/<id>` sets it.
  final viewSections = <String, String>{};

  @override
  Future<List<ViewSummaryDto>> views() async => [
    ViewSummaryDto(id: 'list', name: 'All', layout: ViewLayoutDto.list, section: viewSections['list']),
    ViewSummaryDto(
      id: 'board',
      name: 'Board',
      layout: ViewLayoutDto.kanban,
      groupBy: 'status',
      section: viewSections['board'],
    ),
  ];

  @override
  Future<ViewSummaryDto> updateView(String id, ViewUpdateRequest request) async {
    final section = request.section?.trim() ?? '';
    section.isEmpty ? viewSections.remove(id) : viewSections[id] = section;
    return (await views()).firstWhere((view) => view.id == id);
  }

  @override
  Future<ViewResultDto> view(String id) async {
    viewLoads++;
    final all = items_.values.toList();
    if (id == 'list') {
      return ViewResultDto(id: id, name: 'All', layout: ViewLayoutDto.list, groups: [ViewGroupDto('', all)]);
    }
    return ViewResultDto(
      id: id,
      name: 'Board',
      layout: ViewLayoutDto.kanban,
      groupBy: 'status',
      groups: [
        for (final status in ['todo', 'in-progress', 'done'])
          ViewGroupDto(status, all.where((i) => i.status == status).toList()),
      ],
    );
  }

  @override
  Future<List<LintIssueDto>> lint() async => const [];

  @override
  Stream<BacklogChangeEvent> changes() => _changes.stream;

  static ItemDto _with(ItemDto item, {String? status, String? priority, String? body}) => ItemDto(
    id: item.id,
    title: item.title,
    type: item.type,
    status: status ?? item.status,
    category: _workflow.categoryOf(status ?? item.status),
    priority: priority ?? item.priority,
    labels: item.labels,
    body: body ?? item.body,
  );
}
