import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/foundation.dart';

import '../../../shared/debounced_changes.dart';
import 'board_filter.dart';

/// State of the board screen: the saved views, the evaluated current view and
/// the lint summary. Reloads by itself when the backlog changes on disk.
class BoardController extends ChangeNotifier {
  BoardController(this._api, {Duration refreshDelay = const Duration(milliseconds: 300), this.onViewChosen})
    : _refreshDelay = refreshDelay;

  /// Called with the view the user switches to (or saves and opens), so
  /// that it can be remembered for the next visit of the project.
  final ValueChanged<String>? onViewChosen;

  /// Fields whose value a card can get by being dropped into a column.
  static const movableFields = {'status', 'priority', 'type', 'milestone', 'assignee'};

  final BacklogApi _api;
  final Duration _refreshDelay;
  final _notices = StreamController<String>.broadcast();
  DebouncedChanges? _changes;
  int _generation = 0;

  /// Parts of the backlog changed since the last refresh that loaded them.
  final _stale = <BacklogPart>{};

  WorkflowDto? workflow;
  List<ViewSummaryDto> views = const [];
  String? selectedViewId;

  /// The project's dashboard takes the place of the current view; picking a
  /// view or narrowing the board goes back to it.
  bool dashboard = false;
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

  /// Grouping chosen in the header for the current view only (null: the
  /// view's own; '' ungrouped). Reset when another view is selected.
  String? groupByOverride;

  /// Fields the header offers to group by.
  static const groupableFields = ['status', 'priority', 'type', 'milestone', 'assignee', 'labels', 'epic'];

  /// One-off messages for the user (failed moves and the like).
  Stream<String> get notices => _notices.stream;

  bool get canMove => result?.layout == ViewLayoutDto.kanban && movableFields.contains(result?.groupBy);

  /// Cards can be dragged within their column: a kanban view sorted by
  /// `rank` first.
  bool get canRank =>
      result?.layout == ViewLayoutDto.kanban && result?.groupBy != null && result?.sort.firstOrNull == 'rank';

  int get lintErrors => lint.where((issue) => issue.isError).length;

  /// The milestone the board is about: the one chosen in [filter], else
  /// the one the current view requires; null for none or several. Starts
  /// from the board (Implement epic) default to it.
  String? get milestone => switch (filter.valuesFor(FilterFacet.milestone)) {
    final chosen when chosen.length == 1 => chosen.single,
    final chosen when chosen.isEmpty => result?.milestone,
    _ => null,
  };

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
  Future<bool> saveFilterAsView(String name, {String? section, bool pinned = false}) async {
    try {
      final created = await _api.createView(
        NewViewRequest(
          name: name,
          section: section,
          pinned: pinned,
          base: selectedViewId,
          conditions: filter.toConditions(),
        ),
      );
      filter = BoardFilter.none;
      selectedViewId = created.id;
      dashboard = false;
      onViewChosen?.call(created.id);
    } catch (e) {
      _notices.add('$e');
      return false;
    }
    await refresh();
    return true;
  }

  /// Views pinned to the phone's bottom bar, in list order.
  List<ViewSummaryDto> get pinnedViews => [
    for (final view in views)
      if (view.pinned) view,
  ];

  /// Pins view [id] to the phone's bottom bar, or unpins it.
  Future<void> setPinned(String id, bool pinned) async {
    try {
      await _api.updateView(id, ViewUpdateRequest.pinned(pinned));
    } catch (e) {
      _notices.add('$e');
    }
    await refresh(quiet: true);
  }

  /// Narrows the board to everything under [epicId] (replacing any other
  /// epic in the filter); the filter bar shows it as a removable chip.
  void scopeToEpic(String epicId) {
    var next = filter;
    for (final other in filter.valuesFor(FilterFacet.epic)) {
      next = next.toggle(FilterFacet.epic, other);
    }
    setFilter(next.toggle(FilterFacet.epic, epicId));
  }

  /// The epic the board is scoped to, if exactly one is chosen.
  String? get scopedEpic => switch (filter.valuesFor(FilterFacet.epic)) {
    final epics when epics.length == 1 => epics.single,
    _ => null,
  };

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

  /// How many items of the current view have each facet value.
  Map<FilterFacet, Map<String, int>> get filterCounts =>
      BoardFilter.counts(result?.groups.expand((group) => group.items) ?? const [], index: index);

  void setFilter(BoardFilter next) {
    filter = next;
    dashboard = false;
    notifyListeners();
  }

  /// Shows the dashboard instead of the current view.
  void showDashboard() {
    dashboard = true;
    notifyListeners();
  }

  Future<void> start({String? viewId}) async {
    // Plan changes too: they start and end AI reviews, which cards show.
    _changes ??= DebouncedChanges(
      _api,
      (changed) => unawaited(refresh(quiet: true, changed: changed)),
      delay: _refreshDelay,
      watched: BacklogPart.values.toSet(),
    );
    selectedViewId = viewId;
    await refresh();
  }

  Future<void> selectView(String id) async {
    selectedViewId = id;
    dashboard = false;
    onViewChosen?.call(id);
    groupByOverride = null;
    await refresh();
  }

  /// Regroups the current view by [field] for this session; null goes back
  /// to the view's own grouping.
  Future<void> setGroupBy(String? field) async {
    groupByOverride = field;
    await refresh();
  }

  /// Agents holding a live claim, with how many items each holds, busiest
  /// first — the "People" part of the navigation.
  List<(String, int)> get people {
    final counts = <String, int>{};
    for (final item in index.values) {
      final claim = item.claim;
      if (claim != null && !claim.expired && !item.isDone) counts[claim.agent] = (counts[claim.agent] ?? 0) + 1;
    }
    return counts.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1));
  }

  /// Narrows the board to what [agent] works on (assignee or claim).
  void showPerson(String agent) {
    var next = filter;
    for (final other in filter.valuesFor(FilterFacet.person)) {
      next = next.toggle(FilterFacet.person, other);
    }
    setFilter(next.toggle(FilterFacet.person, agent));
  }

  /// Reloads everything, or with [changed] only what depends on those parts
  /// of the backlog (and the current view); [quiet] keeps the current
  /// content visible meanwhile.
  Future<void> refresh({bool quiet = false, Set<BacklogPart>? changed}) async {
    final generation = ++_generation;
    if (!quiet) {
      loading = true;
      notifyListeners();
    }
    // A newer refresh discards an older one, so it loads its parts too.
    _stale.addAll(changed ?? BacklogPart.values);
    final wanted = workflow == null || error != null ? BacklogPart.values.toSet() : {..._stale};
    bool any(Set<BacklogPart> parts) => wanted.any(parts.contains);
    try {
      // The requests are independent, so they run at the same time. The
      // current view is asked for right away too; its answer is used only when
      // it is still the view to show (it may have been deleted meanwhile).
      final groupBy = groupByOverride;
      final guessed = selectedViewId;
      // The view names its items only; they come from the index.
      final early = guessed == null ? null : _api.view(guessed, groupBy: groupBy, idsOnly: true);
      unawaited(early?.then<void>((_) {}, onError: (Object _) {})); // an unused answer may fail silently
      final workflowRequest = any(const {BacklogPart.workflow}) ? _api.workflow() : null;
      final viewsRequest = any(const {BacklogPart.workflow, BacklogPart.items, BacklogPart.views})
          ? _api.views()
          : null;
      final lintRequest = any(const {BacklogPart.workflow, BacklogPart.items, BacklogPart.views}) ? _api.lint() : null;
      // Items carry the AI review state of the plan.
      final itemsRequest = any(const {BacklogPart.workflow, BacklogPart.items, BacklogPart.plan})
          ? _api.items(includeDone: true)
          : null;
      await Future.wait<Object>([?workflowRequest, ?viewsRequest, ?lintRequest, ?itemsRequest]);
      final loadedWorkflow = await workflowRequest ?? workflow;
      final loadedViews = await viewsRequest ?? views;
      final loadedLint = await lintRequest ?? lint;
      final loadedItems = await itemsRequest ?? index.values;
      final id = _pickView(loadedViews);
      final loadedResult = id == null
          ? null
          : await (id == guessed && early != null ? early : _api.view(id, groupBy: groupBy, idsOnly: true));
      if (generation != _generation) return; // a newer refresh won
      workflow = loadedWorkflow;
      views = loadedViews;
      lint = loadedLint;
      index = {for (final item in loadedItems) item.id: item};
      selectedViewId = id;
      result = loadedResult?.resolve(index);
      error = null;
      _stale.removeAll(wanted);
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
  /// Also works for an item the view leaves out but shows as the header of
  /// its children (an epic): it changes the field without moving a card.
  Future<void> move(ItemDto item, String key) async {
    final current = result;
    final field = current?.groupBy;
    if (current == null || field == null || !canMove) return;
    final from = current.groups.where((group) => group.items.any((i) => i.id == item.id)).firstOrNull;
    if (from == null) {
      if (valueOf(item, field) == key) return;
    } else {
      if (from.key == key) return;
      result = _moved(current, item, key);
      notifyListeners();
    }
    try {
      await _api.updateItem(item.id, ItemUpdateRequest(changes: [ItemUpdateRequest.set(field, key)]));
    } catch (e) {
      _notices.add('${item.id}: $e');
    }
    await refresh(quiet: true);
  }

  /// Drops [item] onto [target] in the same column: it takes the place of
  /// [target] (after it when coming from above, before it from below) and
  /// gets a `rank` there.
  Future<void> rank(ItemDto item, ItemDto target) async {
    final current = result;
    if (current == null || !canRank || item.id == target.id) return;
    final group = current.groups
        .where((g) => g.items.any((i) => i.id == item.id) && g.items.any((i) => i.id == target.id))
        .firstOrNull;
    if (group == null) return;
    final order = reordered(group.ids, item.id, target.id);
    final byId = {for (final i in group.items) i.id: i};
    result = current.withGroups([
      for (final g in current.groups) g == group ? ViewGroupDto(g.key, [for (final id in order) byId[id]!]) : g,
    ]);
    notifyListeners();
    try {
      await _api.rank(item.id, RankRequest(order));
    } catch (e) {
      _notices.add('${item.id}: $e');
    }
    await refresh(quiet: true);
  }

  /// [ids] with [moved] in the place of [target]: after it when [moved] was
  /// above it, else before it.
  static List<String> reordered(List<String> ids, String moved, String target) {
    final down = ids.indexOf(moved) < ids.indexOf(target);
    final rest = [...ids]..remove(moved);
    return rest..insert(rest.indexOf(target) + (down ? 1 : 0), moved);
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

  /// The value of one of the [movableFields] of [item] (`''` for none, like
  /// the key of the column without a value).
  static String valueOf(ItemDto item, String field) =>
      switch (field) {
        'status' => item.status,
        'priority' => item.priority,
        'type' => item.type,
        'milestone' => item.milestone,
        'assignee' => item.assignee,
        _ => null,
      } ??
      '';

  String? _pickView(List<ViewSummaryDto> available) {
    if (available.isEmpty) return null;
    final ids = available.map((view) => view.id);
    if (selectedViewId != null && ids.contains(selectedViewId)) return selectedViewId;
    return ids.contains('board') ? 'board' : ids.first;
  }

  static ViewResultDto _moved(ViewResultDto result, ItemDto item, String key) => result.withGroups([
    for (final group in result.groups)
      ViewGroupDto(group.key, [if (group.key == key) item, ...group.items.where((i) => i.id != item.id)]),
  ]);

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    unawaited(_notices.close());
    super.dispose();
  }
}
