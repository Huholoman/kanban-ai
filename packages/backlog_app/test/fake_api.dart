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
  List<String> touches = const [],
  List<String> conflictsWith = const [],
  bool ready = false,
  bool needsHuman = false,
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
  touches: touches,
  conflicting: conflictsWith.isNotEmpty,
  conflictsWith: conflictsWith,
  ready: ready,
  needsHuman: needsHuman,
  body: body,
);

/// In-memory [BacklogApi]: a kanban `board` grouped by status and a `list`
/// view, edits recorded in [updates].
final class FakeBacklogApi implements BacklogApi {
  FakeBacklogApi(Iterable<ItemDto> items) : items_ = {for (final item in items) item.id: item};

  final Map<String, ItemDto> items_;
  final updates = <(String, ItemUpdateRequest)>[];
  final claims = <(String, String, ClaimRequest)>[];

  /// The discussion of each item; [comment] appends (author `you` when the
  /// request names none) and answers an open question.
  final discussions = <String, List<CommentDto>>{};
  final _changes = StreamController<BacklogChangeEvent>.broadcast();
  int viewLoads = 0;

  /// Someone listens to the live updates (the WebSocket would be open).
  bool get listening => _changes.hasListener;
  Object? failNextUpdate;

  /// Simulates an agent editing a file on disk.
  void externalChange(ItemDto item) {
    items_[item.id] = item;
    _changes.add(BacklogChangeEvent(['items/${item.id}.md']));
  }

  /// What backlog.yaml would say under `appearance`.
  AppearanceDto appearance = const AppearanceDto();

  @override
  Future<WorkflowDto> workflow() async => WorkflowDto(
    statuses: _workflow.statuses,
    priorities: _workflow.priorities,
    types: _workflow.types,
    defaultStatus: _workflow.defaultStatus,
    defaultPriority: _workflow.defaultPriority,
    defaultType: _workflow.defaultType,
    appearance: appearance,
  );

  /// Simulates an edit of backlog.yaml.
  void configChange() => _changes.add(const BacklogChangeEvent(['backlog.yaml']));

  @override
  Future<List<ItemDto>> items({bool includeDone = false}) async =>
      items_.values.where((i) => includeDone || !i.isDone).toList();

  @override
  Future<ItemDetailDto> item(String reference) async {
    final found = items_[reference];
    if (found == null) throw BacklogApiException(404, 'not_found', 'No item "$reference".');
    ItemLinkDto link(ItemDto item) =>
        ItemLinkDto(id: item.id, title: item.title, status: item.status, category: item.category);
    ItemLinkDto linkTo(String id) => items_[id] == null ? ItemLinkDto(id: id) : link(items_[id]!);
    final children = items_.values.where((i) => i.parent == found.id).toList();
    return ItemDetailDto(
      item: _with(found, children: Progress(children.where((c) => c.isDone).length, children.length)),
      parent: found.parent == null ? null : link(items_[found.parent]!),
      children: [for (final child in children) link(child)],
      dependencies: [for (final id in found.dependsOn) linkTo(id)],
      dependents: [
        for (final other in items_.values)
          if (other.dependsOn.contains(found.id)) link(other),
      ],
      related: [for (final id in found.related) linkTo(id)],
      conflicts: [for (final id in found.conflictsWith) linkTo(id)],
      waiting: [
        for (final other in items_.values)
          if (other.conflictsWith.contains(found.id)) link(other),
      ],
      discussion: discussions[found.id] ?? const [],
    );
  }

  @override
  Future<ItemDetailDto> comment(String reference, CommentRequest request) async {
    final comments = discussions[reference] ??= [];
    comments.add(
      CommentDto(
        author: request.author ?? 'you',
        at: DateTime.utc(2026, 10, 31, 12, comments.length),
        text: request.text,
        question: request.question,
      ),
    );
    items_[reference] = _with(items_[reference]!, needsHuman: request.question);
    return item(reference);
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

  /// Section and columns of each view, as `PATCH /api/views/<id>` sets them.
  final viewSections = <String, String>{};
  final viewColumns = <String, List<String>>{};
  final pinnedViews = <String>{};

  @override
  Future<List<ViewSummaryDto>> views() async => [
    for (final (index, request) in createdViews.indexed)
      ViewSummaryDto(
        id: 'saved-${index + 1}',
        name: request.name,
        layout: ViewLayoutDto.kanban,
        groupBy: 'status',
        section: request.section,
        pinned: request.pinned || pinnedViews.contains('saved-${index + 1}'),
      ),
    ViewSummaryDto(
      id: 'list',
      name: 'All',
      layout: ViewLayoutDto.list,
      section: viewSections['list'],
      pinned: pinnedViews.contains('list'),
      count: items_.length,
    ),
    ViewSummaryDto(
      id: 'board',
      name: 'Board',
      layout: ViewLayoutDto.kanban,
      groupBy: 'status',
      section: viewSections['board'],
      pinned: pinnedViews.contains('board'),
      count: items_.values.where((i) => const ['todo', 'in-progress', 'done'].contains(i.status)).length,
    ),
  ];

  /// Views saved from the app.
  final createdViews = <NewViewRequest>[];

  @override
  Future<ViewSummaryDto> createView(NewViewRequest request) async {
    createdViews.add(request);
    return ViewSummaryDto(id: 'saved-${createdViews.length}', name: request.name, layout: ViewLayoutDto.kanban);
  }

  @override
  Future<ViewSummaryDto> updateView(String id, ViewUpdateRequest request) async {
    if (request.changesSection) {
      final section = request.section?.trim() ?? '';
      section.isEmpty ? viewSections.remove(id) : viewSections[id] = section;
    }
    if (request.pinned case final pinned?) {
      pinned ? pinnedViews.add(id) : pinnedViews.remove(id);
    }
    if (request.changesColumns) {
      final columns = request.columns;
      columns == null || columns.isEmpty ? viewColumns.remove(id) : viewColumns[id] = columns;
    }
    return (await views()).firstWhere((view) => view.id == id);
  }

  @override
  Future<ViewResultDto> view(String id, {String? groupBy}) async {
    viewLoads++;
    final all = items_.values.toList();
    if (groupBy == 'priority') {
      return ViewResultDto(
        id: id,
        name: 'Board',
        layout: ViewLayoutDto.kanban,
        groupBy: 'priority',
        groups: [
          for (final priority in _workflow.priorities)
            ViewGroupDto(priority, all.where((i) => i.priority == priority).toList()),
        ],
      );
    }
    if (id == 'list') {
      return ViewResultDto(id: id, name: 'All', layout: ViewLayoutDto.list, groups: [ViewGroupDto('', all)]);
    }
    return ViewResultDto(
      id: id,
      name: 'Board',
      layout: ViewLayoutDto.kanban,
      groupBy: 'status',
      columns: viewColumns[id],
      groups: [
        for (final status in viewColumns[id] ?? ['todo', 'in-progress', 'done'])
          ViewGroupDto(status, all.where((i) => i.status == status).toList()),
      ],
    );
  }

  @override
  Future<List<LintIssueDto>> lint() async => const [];

  @override
  Stream<BacklogChangeEvent> changes() => _changes.stream;

  /// The dispatcher's plan; [startAgent] and [stopAgent] record their calls
  /// and answer with [afterStart] / [afterStop] (or fail with [failStart]).
  DispatchDto plan = DispatchDto.off;
  DispatchDto? afterStart;
  DispatchDto? afterStop;
  Object? failStart;
  final started = <String>[];

  /// Items started with `fresh: true`.
  final startedFresh = <String>[];
  final stopped = <String>[];
  AgentLogDto? log;

  /// Simulates the server reporting a new plan.
  void dispatchChange(DispatchDto next) {
    plan = next;
    _changes.add(const BacklogChangeEvent.dispatch());
  }

  @override
  Future<DispatchDto> dispatch() async => plan;

  @override
  Future<DispatchDto> startAgent(String reference, {bool fresh = false}) async {
    if (failStart case final error?) throw error;
    started.add(reference);
    if (fresh) startedFresh.add(reference);
    return plan = afterStart ?? plan;
  }

  @override
  Future<DispatchDto> stopAgent(String reference) async {
    stopped.add(reference);
    return plan = afterStop ?? plan;
  }

  @override
  Future<AgentLogDto> agentLog(String reference, {int lines = 100}) async =>
      log ?? (throw BacklogApiException(404, 'not_found', 'No agent has run for $reference.'));

  /// What [followAgentLog] streams; add updates to it to simulate the server.
  final agentLogUpdates = StreamController<AgentLogUpdateDto>.broadcast();

  /// Items whose log is followed now.
  final followedLogs = <String>[];

  @override
  Stream<AgentLogUpdateDto> followAgentLog(String reference, {int lines = 200}) {
    late final StreamController<AgentLogUpdateDto> controller;
    StreamSubscription<AgentLogUpdateDto>? subscription;
    controller = StreamController<AgentLogUpdateDto>(
      onListen: () {
        followedLogs.add(reference);
        subscription = agentLogUpdates.stream.where((u) => u.item == reference).listen(controller.add);
      },
      onCancel: () {
        followedLogs.remove(reference);
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  static ItemDto _with(
    ItemDto item, {
    String? status,
    String? priority,
    String? body,
    Progress? children,
    bool? needsHuman,
  }) => ItemDto(
    id: item.id,
    title: item.title,
    type: item.type,
    status: status ?? item.status,
    category: _workflow.categoryOf(status ?? item.status),
    priority: priority ?? item.priority,
    labels: item.labels,
    touches: item.touches,
    conflicting: item.conflicting,
    conflictsWith: item.conflictsWith,
    ready: item.ready,
    parent: item.parent,
    dependsOn: item.dependsOn,
    children: children ?? item.children,
    needsHuman: needsHuman ?? item.needsHuman,
    body: body ?? item.body,
  );
}

ProjectDto fakeProject(String id, {String? error}) =>
    ProjectDto(id: id, name: 'Project $id', path: '/srv/$id/backlog', error: error);

/// In-memory [ProjectsApi]: [list] as the registry, one [FakeBacklogApi]
/// per project in [backlogs]; [failure] is thrown by [projects].
final class FakeProjectsApi implements ProjectsApi {
  FakeProjectsApi(this.backlogs, {List<ProjectDto>? list, this.failure})
    : list = list ?? [for (final id in backlogs.keys) fakeProject(id)];

  final Map<String, FakeBacklogApi> backlogs;
  List<ProjectDto> list;
  Object? failure;

  /// Projects whose API was asked for, in order.
  final opened = <String>[];

  @override
  Future<List<ProjectDto>> projects() async {
    if (failure case final error?) throw error;
    return list;
  }

  @override
  BacklogApi project(String id) {
    opened.add(id);
    return backlogs[id]!;
  }
}
