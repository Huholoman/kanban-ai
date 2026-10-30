import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/foundation.dart';

import '../../../shared/debounced_changes.dart';
import 'board_filter.dart';

/// State of the board screen: the saved views, the evaluated current view and
/// the lint summary. Reloads by itself when the backlog changes on disk.
class BoardController extends ChangeNotifier {
  BoardController(this._api, {Duration refreshDelay = const Duration(milliseconds: 300)})
    : _refreshDelay = refreshDelay;

  /// Fields whose value a card can get by being dropped into a column.
  static const movableFields = {'status', 'priority', 'type', 'milestone', 'assignee'};

  final BacklogApi _api;
  final Duration _refreshDelay;
  final _notices = StreamController<String>.broadcast();
  DebouncedChanges? _changes;
  int _generation = 0;

  WorkflowDto? workflow;
  List<ViewSummaryDto> views = const [];
  String? selectedViewId;
  ViewResultDto? result;
  List<LintIssueDto> lint = const [];

  /// Every item including finished ones, for parents and dependencies that
  /// the current view does not show.
  Map<String, ItemDto> index = const {};
  bool loading = false;
  Object? error;

  /// Narrows the shown items; kept when switching views.
  BoardFilter filter = BoardFilter.none;

  /// Parents whose children are folded away on the board.
  Set<String> collapsed = const {};

  /// Sections of the view list that are folded.
  Set<String> collapsedSections = const {};

  /// One-off messages for the user (failed moves and the like).
  Stream<String> get notices => _notices.stream;

  bool get canMove => result?.layout == ViewLayoutDto.kanban && movableFields.contains(result?.groupBy);

  int get lintErrors => lint.where((issue) => issue.isError).length;

  /// The current view after [filter].
  ViewResultDto? get visible {
    final current = result;
    return current == null ? null : filter.apply(current, index);
  }

  /// Items of the current view before and after [filter].
  ({int shown, int total}) get counts {
    int count(ViewResultDto? view) => view?.groups.fold<int>(0, (sum, group) => sum + group.items.length) ?? 0;
    return (shown: count(visible), total: count(result));
  }

  /// What the filter can offer for the current view.
  Map<FilterFacet, List<String>> get filterOptions => BoardFilter.options(
    result?.groups.expand((group) => group.items) ?? const [],
    workflow,
    current: filter,
    index: index,
  );

  /// Views grouped for the side panel: those without a section first (key
  /// null), then the sections alphabetically; views keep their order inside.
  List<(String?, List<ViewSummaryDto>)> get viewSections {
    final names = {for (final view in views) ?view.section}.toList()..sort();
    return [
      for (final section in [null, ...names])
        if (views.where((view) => view.section == section).toList() case final members when members.isNotEmpty)
          (section, members),
    ];
  }

  List<String> get sectionNames => [for (final (name, _) in viewSections) ?name];

  void toggleSection(String name) {
    collapsedSections = collapsedSections.contains(name)
        ? ({...collapsedSections}..remove(name))
        : {...collapsedSections, name};
    notifyListeners();
  }

  /// The current view groups its items, so its columns can be chosen.
  bool get canEditColumns => result?.groupBy != null;

  /// Values the current view's columns can be picked from: the shown ones in
  /// their order, then the rest the workflow knows for the grouping field.
  List<String> get columnOptions {
    final current = result;
    if (current == null || current.groupBy == null) return const [];
    final flow = workflow;
    final known = switch (current.groupBy) {
      'status' => [...?flow?.statuses.map((status) => status.id)],
      'priority' => [...?flow?.priorities],
      'type' => [...?flow?.types],
      'milestone' => [...?flow?.milestones.map((milestone) => milestone.id)],
      _ => const <String>[],
    };
    return {...current.groups.map((group) => group.key).where((key) => key.isNotEmpty), ...known}.toList();
  }

  /// Saves the columns of the current view; null goes back to the default.
  Future<void> setColumns(List<String>? columns) async {
    final id = selectedViewId;
    if (id == null) return;
    try {
      await _api.updateView(id, ViewUpdateRequest.columns(columns));
    } catch (e) {
      _notices.add('$e');
    }
    await refresh(quiet: true);
  }

  /// Saves the current view narrowed by [filter] as a new view and switches
  /// to it (with the filter cleared, the view now does the filtering).
  Future<bool> saveFilterAsView(String name, {String? section}) async {
    try {
      final created = await _api.createView(
        NewViewRequest(name: name, section: section, base: selectedViewId, conditions: filter.toConditions()),
      );
      filter = BoardFilter.none;
      selectedViewId = created.id;
    } catch (e) {
      _notices.add('$e');
      return false;
    }
    await refresh();
    return true;
  }

  /// Moves view [id] to [section] (null or blank: out of any section).
  Future<void> moveView(String id, String? section) async {
    try {
      await _api.updateView(id, ViewUpdateRequest.section(section));
    } catch (e) {
      _notices.add('$e');
    }
    await refresh(quiet: true);
  }

  void toggleCollapsed(String id) {
    collapsed = collapsed.contains(id) ? ({...collapsed}..remove(id)) : {...collapsed, id};
    notifyListeners();
  }

  void setFilter(BoardFilter next) {
    filter = next;
    notifyListeners();
  }

  Future<void> start({String? viewId}) async {
    _changes ??= DebouncedChanges(_api, () => unawaited(refresh(quiet: true)), delay: _refreshDelay);
    selectedViewId = viewId;
    await refresh();
  }

  Future<void> selectView(String id) async {
    selectedViewId = id;
    await refresh();
  }

  /// Reloads everything; [quiet] keeps the current content visible meanwhile.
  Future<void> refresh({bool quiet = false}) async {
    final generation = ++_generation;
    if (!quiet) {
      loading = true;
      notifyListeners();
    }
    try {
      final loadedWorkflow = await _api.workflow();
      final loadedViews = await _api.views();
      final loadedLint = await _api.lint();
      final loadedItems = await _api.items(includeDone: true);
      final id = _pickView(loadedViews);
      final loadedResult = id == null ? null : await _api.view(id);
      if (generation != _generation) return; // a newer refresh won
      workflow = loadedWorkflow;
      views = loadedViews;
      lint = loadedLint;
      index = {for (final item in loadedItems) item.id: item};
      selectedViewId = id;
      result = loadedResult;
      error = null;
    } catch (e) {
      if (generation != _generation) return;
      error = e;
    } finally {
      if (generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Drops [item] into the column [key]: sets the `group_by` field to it.
  Future<void> move(ItemDto item, String key) async {
    final current = result;
    final field = current?.groupBy;
    if (current == null || field == null || !canMove) return;
    final from = current.groups.where((group) => group.items.any((i) => i.id == item.id)).firstOrNull;
    if (from == null || from.key == key) return;

    result = _moved(current, item, key);
    notifyListeners();
    try {
      await _api.updateItem(item.id, ItemUpdateRequest(changes: [ItemUpdateRequest.set(field, key)]));
    } catch (e) {
      _notices.add('${item.id}: $e');
    }
    await refresh(quiet: true);
  }

  Future<ItemDetailDto?> create(NewItemRequest request) async {
    try {
      final created = await _api.createItem(request);
      unawaited(refresh(quiet: true));
      return created;
    } catch (e) {
      _notices.add('$e');
      return null;
    }
  }

  String? _pickView(List<ViewSummaryDto> available) {
    if (available.isEmpty) return null;
    final ids = available.map((view) => view.id);
    if (selectedViewId != null && ids.contains(selectedViewId)) return selectedViewId;
    return ids.contains('board') ? 'board' : ids.first;
  }

  static ViewResultDto _moved(ViewResultDto result, ItemDto item, String key) => ViewResultDto(
    id: result.id,
    name: result.name,
    layout: result.layout,
    groupBy: result.groupBy,
    fields: result.fields,
    columns: result.columns,
    hidden: result.hidden,
    groups: [
      for (final group in result.groups)
        ViewGroupDto(group.key, [if (group.key == key) item, ...group.items.where((i) => i.id != item.id)]),
    ],
  );

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    unawaited(_notices.close());
    super.dispose();
  }
}
